# Duktape C3 Port — common tasks
justfile := "benchmarks/README.md"

# ── Build ────────────────────────────────────────────────────────────────────

# Build everything (default)
all: build-lib build-batch build-bench build-orig-duktape

# Build the static library (skips c3c if nothing changed — see Makefile)
build-lib:
    @make out/lib.a

# Build the batch test262 runner (skips c3c if nothing changed — see Makefile)
build-batch:
    @make out/test262_runner

# Build the C3 Duktape CLI — the plain runner (skips c3c if nothing changed)
build-bench:
    @make out/duktape_c3

# Build original Duktape v2.7.0 for comparison benchmarks
build-orig-duktape:
    @cc -O2 -o out/duktape_orig benchmarks/duktape_orig.c $(ls duktape/src-separate/*.c) -I.
    @rm -f out/bench_cache_duktape.txt

# Build QuickJS CLI for comparison benchmarks
build-quickjs:
    make -C quickjs qjs
    cp quickjs/qjs out/
    @rm -f out/bench_cache_qjs.txt

# Build with shape pointer cache disabled (`-D NOSHAPECACHE`)
build-noshape t="duktape_c3":
    c3c -D NOSHAPECACHE build "{{t}}"

# Build a specific target: `just build <target>`  (e.g. just build duktape_c3)
build t="duktape_c3":
    c3c build "{{t}}"

# Build the C3 Duktape CLI with debug symbols (-O0) for lldb debugging
build-debug t="duktape_c3":
    c3c -O0 build "{{t}}"

# Build the inspection CLI (`out/duktape_c3_debug`): the `duktape_c3_debug`
# target carries `-D TRACE_VM`, so `-c`/`--format json`/`-t` (`--trace-vm`)
# dump bytecode, dump JSON, and trace every instruction respectively.
build-trace:
    c3c build duktape_c3_debug

# Build with heap verification enabled (`-D HEAP_VERIFY`) — validates GC roots at yield/resume
build-verify t="duktape_c3":
    c3c -D HEAP_VERIFY -O0 build "{{t}}"

# Build duktape_c3 with heap verification and run a JS file
run-verify file="test/simple.js":
    c3c -D HEAP_VERIFY -O0 build duktape_c3
    ./out/duktape_c3 {{file}}

# ── Debugging ─────────────────────────────────────────────────────────────────

# Build duktape_c3 with -O0 and launch lldb
# Usage: just lldb test/simple.js    (basic run + bt on crash)
lldb file="test/simple.js":
    c3c -O0 build duktape_c3
    lldb ./out/duktape_c3 -b -o "run {{file}}" -o "bt"

# Build with NaN-boxing disabled (`-D NONANBOX`)
build-nonanbox t="duktape_c3":
    c3c -D NONANBOX build "{{t}}"

# Build duktape_c3 with NaN-boxing disabled and run a smoke test
test-nonanbox file="test/simple.js":
    c3c -D NONANBOX build duktape_c3
    ./out/duktape_c3 {{file}}

# Clean build artifacts
clean:
    c3c clean

# ── Run ──────────────────────────────────────────────────────────────────────

# Run a single JS file (skips c3c if nothing changed)
run file="test/simple.js":
    @make out/duktape_c3
    ./out/duktape_c3 {{file}}

# Run a JS file as an ESM module (import/export) (skips c3c if nothing changed)
run-module file="test/mod_main.js":
    @make out/duktape_c3
    ./out/duktape_c3 --module {{file}}

# Run all ESM module tests
modules:
    @just build duktape_c3
    bash test/modules/run.sh

# ── Rosetta Code ─────────────────────────────────────────────────────────────

# Run Rosetta Code tests on duktape-c3 (rebuilds first)
rosetta engine="duktape_c3": 
   bash test/rosetta/run.sh ./out/{{engine}}

# ── Test262 ──────────────────────────────────────────────────────────────────

# Run full test262 suite
# Run the full test262 suite (builds test262_runner first)
test262: build-batch
    python3 scripts/run_test262.py

# Run a specific test262 phase (`just test262-phase 2`)
test262-phase phase="0": build-batch
    python3 scripts/run_test262.py --phase {{phase}}

# Detect test contamination: run a phase with --workers 1 in fixed vs shuffled
# order and diff — any delta is a reset bug by definition.
test262-contamination phase="0": build-batch
    python3 scripts/run_test262.py --phase {{phase}} --workers 1 --no-retry-fails --log /tmp/t262_fixed.tsv
    python3 scripts/run_test262.py --phase {{phase}} --workers 1 --no-retry-fails --log /tmp/t262_shuffled.tsv --shuffle
    diff /tmp/t262_fixed.tsv /tmp/t262_shuffled.tsv && echo "CLEAN: no contamination detected" || echo "CONTAMINATION: diff found"

# Guard Heap.reset() against field drift — fails if a new Heap field is not
# touched by reset() and not in the allowlist.
check-heap-drift:
    python3 scripts/check_heap_reset_drift.py

# ── Benchmarks ───────────────────────────────────────────────────────────────

# Run all benchmarks without rebuilding (default: 3 iterations)
bench n="3":
	@test -f out/duktape_c3 || { echo "ERROR: out/duktape_c3 not found — run: c3c build duktape_c3"; exit 1; }
	@test -f out/duktape_orig || { echo "Building original Duktape..."; cc -O2 -o out/duktape_orig benchmarks/duktape_orig.c $(ls duktape/src-separate/*.c) -I.; rm -f out/bench_cache_duktape.txt; }
	@test -f out/qjs || { echo "Building QuickJS..."; make -C quickjs qjs && cp quickjs/qjs out/ && rm -f out/bench_cache_qjs.txt; }
	bash scripts/run_benchmarks.sh {{n}}

# Rebuild duktape_c3 and run all benchmarks
bench-rebuild n="3":
	c3c build duktape_c3
	@test -f out/duktape_orig || { echo "Building original Duktape..."; cc -O2 -o out/duktape_orig benchmarks/duktape_orig.c $(ls duktape/src-separate/*.c) -I.; rm -f out/bench_cache_duktape.txt; }
	@test -f out/qjs || { echo "Building QuickJS..."; make -C quickjs qjs && cp quickjs/qjs out/ && rm -f out/bench_cache_qjs.txt; }
	bash scripts/run_benchmarks.sh {{n}}

# Quick single-engine benchmark (no comparison, skips deep recursion)
bench-fast n="2":
	@test -f out/duktape_c3 || { echo "ERROR: out/duktape_c3 not found — run: c3c build duktape_c3"; exit 1; }
	bash scripts/run_bench_fast.sh {{n}}

# Run a single benchmark file: `just bench-one benchmarks/bench_loop.js`
bench-one file n="3":
    @test -f out/duktape_c3 || { echo "ERROR: out/duktape_c3 not found"; exit 1; }
    ./out/duktape_c3 {{file}}

# Run a single benchmark on original Duktape
bench-orig file:
	@test -f out/duktape_orig || { echo "Building original Duktape..."; cc -O2 -o out/duktape_orig benchmarks/duktape_orig.c $(ls duktape/src-separate/*.c) -I.; }
	./out/duktape_orig {{file}}

# ── Size & Memory Benchmarks ────────────────────────────────────────────────

# Measure binary sizes and peak RSS of all engines
bench-sizes:
	@echo "=== Engine Size & Memory Benchmark ==="
	@test -f out/duktape_c3 || { echo "ERROR: out/duktape_c3 not found — run: c3c build duktape_c3"; exit 1; }
	@test -f out/duktape_orig || { echo "Building original Duktape..."; cc -O2 -o out/duktape_orig benchmarks/duktape_orig.c $(ls duktape/src-separate/*.c) -I.; }
	@test -f out/qjs || { echo "Building QuickJS..."; make -C quickjs qjs && cp quickjs/qjs out/; }
	bash scripts/run_sizes_bench.sh

# Rebuild duktape_c3 and run size/memory benchmark
bench-sizes-rebuild:
	c3c build duktape_c3
	@test -f out/duktape_orig || { echo "Building original Duktape..."; cc -O2 -o out/duktape_orig benchmarks/duktape_orig.c $(ls duktape/src-separate/*.c) -I.; }
	@test -f out/qjs || { echo "Building QuickJS..."; make -C quickjs qjs && cp quickjs/qjs out/; }
	bash scripts/run_sizes_bench.sh

# Measure peak RSS memory usage across engines
bench-memory:
	@test -f out/duktape_c3 || { echo "ERROR: out/duktape_c3 not found — run: c3c build duktape_c3"; exit 1; }
	@test -f out/duktape_orig || { echo "Building original Duktape..."; cc -O2 -o out/duktape_orig benchmarks/duktape_orig.c $(ls duktape/src-separate/*.c) -I.; }
	@test -f out/qjs || { echo "Building QuickJS..."; make -C quickjs qjs && cp quickjs/qjs out/; }
	bash scripts/run_memory_bench.sh

# Compare memory usage: current build only
bench-memory-compare:
	@echo "=== Building ==="
	c3c build duktape_c3
	@echo ""
	@echo "=== CURRENT BUILD ==="
	@bash scripts/run_memory_bench.sh

# ── Help ─────────────────────────────────────────────────────────────────────

# List available commands
list:
    @just --list
