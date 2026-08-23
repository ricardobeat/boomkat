# Boomkat — common tasks
justfile := "benchmarks/README.md"

import 'examples.just'

# ── Build ────────────────────────────────────────────────────────────────────

# Build all primary binaries and Duktape
all: build-lib build-batch build-bench build-duktape

# Build static library (out/lib.a)
build-lib:
    @make out/lib.a

# Build batch test262 runner (out/test262_runner)
build-batch:
    @make out/test262_runner

# Build plain runner CLI (out/boomkat)
build-bench:
    @make out/boomkat

# ── Comparison engines ───────────────────────────────────────────────────────

# Fetch Duktape v2.7.0 and QuickJS
fetch-engines: fetch-duktape fetch-quickjs

# Fetch Duktape v2.7.0 release tarball (contains prebuilt src-separate/)
fetch-duktape:
    #!/usr/bin/env bash
    set -euo pipefail
    if [ -d duktape/src-separate ]; then echo "duktape: ok"; exit 0; fi
    if [ ! -d ../duktape-2.7.0/src-separate ]; then
        echo "Downloading duktape 2.7.0..."
        curl -fsSL https://duktape.org/duktape-2.7.0.tar.xz | tar xJ -C ..
    fi
    rm -f duktape
    ln -s ../duktape-2.7.0 duktape
    echo "duktape: fetched -> ../duktape-2.7.0"

# Clone QuickJS repository into ./quickjs
fetch-quickjs:
    #!/usr/bin/env bash
    set -euo pipefail
    if [ -f quickjs/quickjs.c ]; then echo "quickjs: ok"; exit 0; fi
    echo "Cloning quickjs..."
    git clone --depth 1 https://github.com/bellard/quickjs.git quickjs
    echo "quickjs: cloned"

# Build out/duktape if missing
[private]
duktape-ready: fetch-duktape
    #!/usr/bin/env bash
    set -euo pipefail
    [ -f out/duktape ] && exit 0
    echo "Building original Duktape..."
    cc -O2 -o out/duktape benchmarks/duktape.c $(ls duktape/src-separate/*.c) -I.
    rm -f out/bench_cache_duktape.txt

# Build out/qjs if missing
[private]
qjs-ready: fetch-quickjs
    #!/usr/bin/env bash
    set -euo pipefail
    [ -f out/qjs ] && exit 0
    echo "Building QuickJS..."
    make -C quickjs qjs
    cp quickjs/qjs out/
    rm -f out/bench_cache_qjs.txt

# Build Duktape v2.7.0 for comparison benchmarks
build-duktape: fetch-duktape
    @cc -O2 -o out/duktape benchmarks/duktape.c $(ls duktape/src-separate/*.c) -I.
    @rm -f out/bench_cache_duktape.txt

# Build QuickJS for comparison benchmarks
build-quickjs: fetch-quickjs
    make -C quickjs qjs
    cp quickjs/qjs out/
    @rm -f out/bench_cache_qjs.txt

# Build a specific target (e.g. `just build boomkat`)
build t="boomkat":
    c3c build "{{t}}"

# Build with debug symbols (-O0)
build-debug t="boomkat":
    c3c -O0 build "{{t}}"

# Build inspection CLI (out/boomkat_debug, carries -D TRACE_VM for disasm and tracing)
build-trace:
    c3c build boomkat_debug

# Run golden-bytecode fusion test suite (test/golden_bytecode/)
test-golden-bytecode: build-trace
    python3 scripts/run_golden_bytecode.py --check-noop

# Regenerate test/golden_bytecode/*.expected from current compiler disasm
update-golden-bytecode: build-trace
    python3 scripts/run_golden_bytecode.py --update

# Build with heap verification enabled (-D HEAP_VERIFY -O0)
build-verify t="boomkat":
    c3c -D HEAP_VERIFY -O0 build "{{t}}"

# Build with heap verification and run a JS file
run-verify file="test/simple.js":
    c3c -D HEAP_VERIFY -O0 build boomkat
    ./out/boomkat {{file}}

# ── Debugging ─────────────────────────────────────────────────────────────────

# Build with -O0 and run file under lldb (prints backtrace on crash)
lldb file="test/simple.js":
    c3c -O0 build boomkat
    lldb ./out/boomkat -b -o "run {{file}}" -o "bt"

# Build AddressSanitizer test262 runner (out/test262_runner_asan)
build-asan:
    @make out/test262_runner_asan

# Build with NaN-boxing disabled (-D NONANBOX)
build-nonanbox t="boomkat":
    c3c -D NONANBOX build "{{t}}"

# Build with NaN-boxing disabled and run a JS file
test-nonanbox file="test/simple.js":
    c3c -D NONANBOX build boomkat
    ./out/boomkat {{file}}

# Clean build artifacts
clean:
    c3c clean

# ── Packaging ────────────────────────────────────────────────────────────────

# Package engine as .c3l library (dist/boomkat.c3l/ and dist/boomkat.link.c3l/)
pack:
    bash {{justfile_directory()}}/scripts/pack_c3l.sh
    bash {{justfile_directory()}}/scripts/pack_c3l.sh --link

# ── Run ──────────────────────────────────────────────────────────────────────

# Run a JS file with boomkat
run file="test/simple.js":
    @make out/boomkat
    ./out/boomkat {{file}}

# Run a JS file as an ESM module (--module)
run-module file="test/modules/t01_named/main.js":
    @make out/boomkat
    ./out/boomkat --module {{file}}

# Run all ESM module tests (runtime fixtures and syntax error checks)
modules:
    @just build boomkat
    bash test/modules/run.sh
    bash test/modules/syntax_positions.sh
    bash test/modules/export_names.sh

# Run local test suite (test/*.js and ESM fixtures; skips test_async_500k.js stress test)
test-local:
    @just build boomkat
    bash test/run_local.sh

# Run GC-lifetime tests under allocation stress (-D GC_STRESS and ASAN), collecting at every allocation
test-gc-stress:
    @make out/boomkat_gc_stress
    bash scripts/run_gc_stress.sh

# Run multiple Heap.reset() cycles under ASAN to verify reset boundary cleanup and cache teardown
test-heap-reset:
    @make out/test262_runner_asan
    bash scripts/run_heap_reset.sh

# Check peak RSS on early for-in exit (break/return/throw) to ensure enumeration states release memory
test-forin-rss:
    @just build boomkat
    bash scripts/check_forin_early_exit_rss.sh

# Check peak RSS when abandoning generators in try blocks to ensure Catcher chains do not leak
test-generator-catcher-rss:
    @just build boomkat
    bash scripts/check_generator_catcher_rss.sh

# Verify linear time scaling for loop string concatenations (s += ...) across input sizes
test-string-concat-scaling:
    @just build boomkat
    bash scripts/check_string_concat_scaling.sh

# Verify linear scaling when interning short-lived strings, running each size in a fresh process
test-string-table-scaling:
    @just build boomkat
    bash scripts/check_string_table_scaling.sh

# Verify linear memory scaling (peak RSS) when dynamically adding properties to single objects
test-unshared-shape-hash-rss:
    @just build boomkat
    bash scripts/check_unshared_shape_hash_rss.sh

# Run local test corpus under ASAN to verify compiler buffer sizing and internal memory bounds
test-compile-asan:
    @make out/test262_runner_asan
    bash scripts/check_compile_asan.sh

# ── JS test suites ───────────────────────────────────────────────────────────

# Run internal engine conformance tests
engine-tests engine="boomkat":
   bash test/engine/run.sh ./out/{{engine}}

# Run verbatim Rosetta Code suite
rosetta engine="boomkat":
   bash test/rosetta-verbatim/run.sh ./out/{{engine}}

# Verify verbatim samples against rosettacode.org
rosetta-check:
   python3 scripts/fetch_rosetta.py --check test/rosetta-verbatim

# ── Test262 ──────────────────────────────────────────────────────────────────

# Run full test262 suite
test262: build-batch
    python3 scripts/run_test262.py

# Run a specific test262 phase (e.g. `just test262-phase 2`)
test262-phase phase="0": build-batch
    python3 scripts/run_test262.py --phase {{phase}}

# ── TypeScript conformance ───────────────────────────────────────────────────

# Run TypeScript erasable-syntax conformance corpus (tsc oracle)
ts-conformance phase-dir="":
    @test -d test/typescript/conformance-src || { echo "ERROR: corpus missing — run: python3 scripts/fetch_ts_conformance.py"; exit 1; }
    @if [ -n "{{phase-dir}}" ]; then python3 scripts/run_ts_conformance.py --phase-dir "{{phase-dir}}"; else python3 scripts/run_ts_conformance.py; fi

# Run TypeScript handbook syntax tests against reference type stripping
ts-handbook:
    @just build boomkat
    bash test/typescript/handbook/run.sh

# Run real-world TS library corpus (microdiff, zustand, valtio)
ts-runtime:
    @just build boomkat
    python3 scripts/verify_ts_libraries.py

# Check test contamination by diffing fixed vs shuffled runs
test262-contamination phase="0": build-batch
    python3 scripts/run_test262.py --phase {{phase}} --workers 1 --no-retry-fails --log /tmp/t262_fixed.tsv
    python3 scripts/run_test262.py --phase {{phase}} --workers 1 --no-retry-fails --log /tmp/t262_shuffled.tsv --shuffle
    diff /tmp/t262_fixed.tsv /tmp/t262_shuffled.tsv && echo "CLEAN: no contamination detected" || echo "CONTAMINATION: diff found"

# Check that all Heap fields are handled by Heap.reset()
check-heap-drift:
    python3 scripts/check_heap_reset_drift.py

# Run zero-failure gate across all test262 phases
test262-gate: build-batch
    bash scripts/test262_gate.sh

# ── Benchmarks ───────────────────────────────────────────────────────────────

# Run all benchmarks without rebuilding (default: 3 iterations)
bench n="3": duktape-ready qjs-ready
	@test -f out/boomkat || { echo "ERROR: out/boomkat not found — run: c3c build boomkat"; exit 1; }
	bash scripts/run_benchmarks.sh {{n}}

# Rebuild boomkat and run all benchmarks
bench-rebuild n="3": duktape-ready qjs-ready
	c3c build boomkat
	bash scripts/run_benchmarks.sh {{n}}

# Clear cached Duktape/QuickJS benchmark results
bench-clear:
	@rm -f out/bench_cache_duktape.txt out/bench_cache_qjs.txt
	@echo "Cleared benchmark caches."

# Quick single-engine benchmark (no comparison, skips deep recursion)
bench-fast n="2":
	@test -f out/boomkat || { echo "ERROR: out/boomkat not found — run: c3c build boomkat"; exit 1; }
	bash scripts/run_bench_fast.sh {{n}}

# Run a single benchmark file (e.g. `just bench-one benchmarks/bench_loop.js`)
bench-one file n="3":
    @test -f out/boomkat || { echo "ERROR: out/boomkat not found"; exit 1; }
    ./out/boomkat {{file}}

# Run a single benchmark on original Duktape
bench-orig file: duktape-ready
	./out/duktape {{file}}

# ── Size & Memory Benchmarks ────────────────────────────────────────────────

# Measure binary sizes and peak RSS of all engines
bench-sizes: duktape-ready qjs-ready
	@echo "=== Engine Size & Memory Benchmark ==="
	@test -f out/boomkat || { echo "ERROR: out/boomkat not found — run: c3c build boomkat"; exit 1; }
	bash scripts/run_sizes_bench.sh

# Rebuild boomkat and run size/memory benchmark
bench-sizes-rebuild: duktape-ready qjs-ready
	c3c build boomkat
	bash scripts/run_sizes_bench.sh

# Measure peak RSS memory usage across engines
bench-memory: duktape-ready qjs-ready
	@test -f out/boomkat || { echo "ERROR: out/boomkat not found — run: c3c build boomkat"; exit 1; }
	bash scripts/run_memory_bench.sh

# Compare memory usage: current build only
bench-memory-compare:
	@echo "=== Building ==="
	c3c build boomkat
	@echo ""
	@echo "=== CURRENT BUILD ==="
	@bash scripts/run_memory_bench.sh

# ── Help ─────────────────────────────────────────────────────────────────────

# List available commands
list:
    @just --list

# Interleaved A/B benchmark against another revision (e.g. `just perf-diff HEAD~1`)
perf-diff *ARGS:
    bash scripts/perf_diff.sh {{ARGS}}

# Profile and disassemble hot symbols (e.g. `just perf-triage /tmp/case.js`)
perf-triage *ARGS:
    bash scripts/perf_triage.sh {{ARGS}}

# Diff compiled bytecode across the library corpus against another build
bytecode-diff *ARGS:
    python3 scripts/bytecode_diff.py {{ARGS}}

# Profile collection pressure: allocations, cycles, marked objects (e.g. `just gc-profile /tmp/case.js`)
gc-profile SCRIPT:
    @make out/boomkat_gcprofile 2>/dev/null || c3c build boomkat_gcprofile
    ./out/boomkat_gcprofile {{SCRIPT}}

# Run ES6+ benchmarks against QuickJS (benchmarks/es6/README.md)
bench-es6 *ARGS:
    bash scripts/run_bench_es6.sh {{ARGS}}

