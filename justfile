# Boomkat — common tasks
justfile := "benchmarks/README.md"

# ── Build ────────────────────────────────────────────────────────────────────

# Build everything (default)
all: build-lib build-batch build-bench build-duktape

# Build the static library (skips c3c if nothing changed — see Makefile)
build-lib:
    @make out/lib.a

# Build the batch test262 runner (skips c3c if nothing changed — see Makefile)
build-batch:
    @make out/test262_runner

# Build the boomkat CLI — the plain runner (skips c3c if nothing changed)
build-bench:
    @make out/boomkat

# Build original Duktape v2.7.0 for comparison benchmarks
build-duktape:
    @cc -O2 -o out/duktape benchmarks/duktape.c $(ls duktape/src-separate/*.c) -I.
    @rm -f out/bench_cache_duktape.txt

# Build QuickJS CLI for comparison benchmarks
build-quickjs:
    make -C quickjs qjs
    cp quickjs/qjs out/
    @rm -f out/bench_cache_qjs.txt

# Build a specific target: `just build <target>`  (e.g. just build boomkat)
build t="boomkat":
    c3c build "{{t}}"

# Build the boomkat CLI with debug symbols (-O0) for lldb debugging
build-debug t="boomkat":
    c3c -O0 build "{{t}}"

# Build the inspection CLI (`out/boomkat_debug`): the `boomkat_debug`
# target carries `-D TRACE_VM`, so `-c`/`--format json`/`-t` (`--trace-vm`)
# dump bytecode, dump JSON, and trace every instruction respectively.
build-trace:
    c3c build boomkat_debug

# Run the golden-bytecode fusion test suite (test/golden_bytecode/): diffs
# `boomkat_debug -c` disasm against checked-in .expected files so a
# compiler change that silently breaks a peephole fusion (ADDI/SUBI,
# INC_VAR, GETPROPC, JMP_N*, ...) fails loudly instead of only showing up
# as an unexplained benchmark regression. --check-noop also asserts the
# `--no-optimize` output is fusion-free (disable_optimize invariant).
test-golden-bytecode: build-trace
    python3 scripts/run_golden_bytecode.py --check-noop

# Regenerate test/golden_bytecode/*.expected from current compiler output.
# Only run this after confirming a disasm diff is an intentional change to
# the fusion (new pass, changed register allocation, etc.), never to paper
# over a regression.
update-golden-bytecode: build-trace
    python3 scripts/run_golden_bytecode.py --update

# Build with heap verification enabled (`-D HEAP_VERIFY`) — validates GC roots at yield/resume
build-verify t="boomkat":
    c3c -D HEAP_VERIFY -O0 build "{{t}}"

# Build boomkat with heap verification and run a JS file
run-verify file="test/simple.js":
    c3c -D HEAP_VERIFY -O0 build boomkat
    ./out/boomkat {{file}}

# ── Debugging ─────────────────────────────────────────────────────────────────

# Build boomkat with -O0 and launch lldb
# Usage: just lldb test/simple.js    (basic run + bt on crash)
lldb file="test/simple.js":
    c3c -O0 build boomkat
    lldb ./out/boomkat -b -o "run {{file}}" -o "bt"

# Build the AddressSanitizer test262 runner (`out/test262_runner_asan`): the
# `test262_runner_asan` target is -O0 with `"sanitize": "address"`, for chasing
# use-after-free / heap-overflow bugs the ordinary runner only shows as a
# sporadic crash. Not part of `just all` (ASAN + -O0 is slow), so build it
# explicitly — a stale ASAN binary reports clean on code it does not contain.
# Usage: just build-asan && echo test/simple.js | ./out/test262_runner_asan --worker
build-asan:
    @make out/test262_runner_asan

# Build with NaN-boxing disabled (`-D NONANBOX`)
build-nonanbox t="boomkat":
    c3c -D NONANBOX build "{{t}}"

# Build boomkat with NaN-boxing disabled and run a smoke test
test-nonanbox file="test/simple.js":
    c3c -D NONANBOX build boomkat
    ./out/boomkat {{file}}

# Clean build artifacts
clean:
    c3c clean

# ── Packaging ────────────────────────────────────────────────────────────────

# Pack the engine as a .c3l library: self-contained copy (dist/jse.c3l/) for
# distribution, and a symlink version (dist/jse.link.c3l/) for local dev.
pack:
    bash {{justfile_directory()}}/scripts/pack_c3l.sh
    bash {{justfile_directory()}}/scripts/pack_c3l.sh --link

# ── Run ──────────────────────────────────────────────────────────────────────

# Run a single JS file (skips c3c if nothing changed)
run file="test/simple.js":
    @make out/boomkat
    ./out/boomkat {{file}}

# Run a JS file as an ESM module (import/export) (skips c3c if nothing changed)
run-module file="test/modules/t01_named/main.js":
    @make out/boomkat
    ./out/boomkat --module {{file}}

# Run all ESM module tests: the runnable fixtures, then the module-syntax
# declaration-position early errors (compile-only, so they need their own driver)
modules:
    @just build boomkat
    bash test/modules/run.sh
    bash test/modules/syntax_positions.sh
    bash test/modules/export_names.sh

# Run the local test suite: every test/*.js under the plain runner, then the
# ESM fixtures under test/modules/ (which need --module, so run.sh owns them).
# test_async_500k.js is excluded — it passes but takes ~20s, so it is a perf
# stress test rather than a regression check; run it directly when relevant.
test-local:
    @just build boomkat
    bash test/run_local.sh

# Run the GC-lifetime tests under a build that collects at every allocation
# (`boomkat_gc_stress`: -D GC_STRESS plus ASAN). Under the normal trigger a
# value that survives an allocating call without being a real GC root is merely
# lucky, so a missed root is invisible to every other gate here and only shows up
# as a field crash on a memory-tight device. This build makes it deterministic.
# Slow by construction — keep the script's list to the tests that exercise
# lifetimes across suspension, microtask, and re-entry boundaries.
test-gc-stress:
    @make out/boomkat_gc_stress
    bash scripts/run_gc_stress.sh

# Assert that exiting a for-in early (break/return/throw) costs no more peak
# RSS than running it to exhaustion. Lives outside test-local because it needs
# /usr/bin/time -l rather than an in-script assertion — the engine exposes no
# GC trigger, so a stranded enumeration state is only visible as RSS growth.
test-forin-rss:
    @just build boomkat
    bash scripts/check_forin_early_exit_rss.sh

# Assert that abandoning a generator suspended inside a try costs no more peak
# RSS than running the same generator to exhaustion. Same reasoning as
# test-forin-rss: a stranded Catcher chain is invisible to script assertions.
test-generator-catcher-rss:
    @just build boomkat
    bash scripts/check_generator_catcher_rss.sh

# Assert that `s += ...` in a loop scales linearly. Lives outside test-local
# because it is a timing comparison of the engine against itself at two input
# sizes; a script cannot assert its own asymptotics. Interning every
# concatenation temporary made this O(n^2).
test-string-concat-scaling:
    @just build boomkat
    bash scripts/check_string_concat_scaling.sh

# Assert that adding properties to one object scales linearly in memory. Same
# reasoning as test-string-concat-scaling: correctness is identical either way,
# so only peak RSS at two sizes separates them. Building the property hash
# table per shape made a single object's growth O(n^2).
test-unshared-shape-hash-rss:
    @just build boomkat
    bash scripts/check_unshared_shape_hash_rss.sh

# Run the local corpus through the ASan build. The compiler sizes its own
# buffers from counters that are easy to get wrong, and a bad bound there is
# silent on the normal build, so this catches what correctness gates cannot.
# The runner executes each file; two are skipped because ASan changes their
# behavior rather than the engine's memory handling (see the script header).
test-compile-asan:
    @make out/test262_runner_asan
    bash scripts/check_compile_asan.sh

# ── JS test suites ───────────────────────────────────────────────────────────

# Run the engine conformance tests (hand-written assert-based)
engine-tests engine="boomkat":
   bash test/engine/run.sh ./out/{{engine}}

# Run the verbatim Rosetta Code samples (unmodified third-party code)
rosetta engine="boomkat":
   bash test/rosetta-verbatim/run.sh ./out/{{engine}}

# Confirm the verbatim samples still match rosettacode.org
rosetta-check:
   python3 scripts/fetch_rosetta.py --check test/rosetta-verbatim

# ── Test262 ──────────────────────────────────────────────────────────────────

# Run full test262 suite
# Run the full test262 suite (builds test262_runner first)
test262: build-batch
    python3 scripts/run_test262.py

# Run a specific test262 phase (`just test262-phase 2`)
test262-phase phase="0": build-batch
    python3 scripts/run_test262.py --phase {{phase}}

# ── TypeScript conformance ───────────────────────────────────────────────────

# Run the TypeScript erasable-syntax conformance corpus (tsc accept/reject
# oracle against the engine; needs `tsc` on PATH and the corpus fetched with
# `python3 scripts/fetch_ts_conformance.py`). The full run takes ~1 minute.
# Subset: `just ts-conformance types`
ts-conformance phase-dir="":
    @test -d test/typescript/conformance-src || { echo "ERROR: corpus missing — run: python3 scripts/fetch_ts_conformance.py"; exit 1; }
    @if [ -n "{{phase-dir}}" ]; then python3 scripts/run_ts_conformance.py --phase-dir "{{phase-dir}}"; else python3 scripts/run_ts_conformance.py; fi

# Run the TypeScript handbook syntax corpus: small doc-organized .ts files
# (one feature area each) diffed against reference output captured from
# node's type stripping, plus reject tests for non-erasable syntax. Regenerate
# the reference files with `bash test/typescript/handbook/run.sh --regen`.
ts-handbook:
    @just build boomkat
    bash test/typescript/handbook/run.sh

# Fetch real-world TS library sources (microdiff, zustand, valtio) into
# test/tscorpus (gitignored) and run each against a driver, requiring stdout
# identical to node's native type stripping. Needs node on PATH; the first
# run needs network, later runs are cached.
ts-runtime:
    @just build boomkat
    python3 scripts/verify_ts_libraries.py

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

# Two-consecutive-run zero-fail gate: runs the full suite twice and requires
# both runs to report 0 fails. Not part of any default path — opt in when you
# need stronger confidence than a single green run (~15 min).
test262-gate: build-batch
    bash scripts/test262_gate.sh

# ── Benchmarks ───────────────────────────────────────────────────────────────

# Run all benchmarks without rebuilding (default: 3 iterations)
bench n="3":
	@test -f out/boomkat || { echo "ERROR: out/boomkat not found — run: c3c build boomkat"; exit 1; }
	@test -f out/duktape || { echo "Building original Duktape..."; cc -O2 -o out/duktape benchmarks/duktape.c $(ls duktape/src-separate/*.c) -I.; rm -f out/bench_cache_duktape.txt; }
	@test -f out/qjs || { echo "Building QuickJS..."; make -C quickjs qjs && cp quickjs/qjs out/ && rm -f out/bench_cache_qjs.txt; }
	bash scripts/run_benchmarks.sh {{n}}

# Rebuild boomkat and run all benchmarks
bench-rebuild n="3":
	c3c build boomkat
	@test -f out/duktape || { echo "Building original Duktape..."; cc -O2 -o out/duktape benchmarks/duktape.c $(ls duktape/src-separate/*.c) -I.; rm -f out/bench_cache_duktape.txt; }
	@test -f out/qjs || { echo "Building QuickJS..."; make -C quickjs qjs && cp quickjs/qjs out/ && rm -f out/bench_cache_qjs.txt; }
	bash scripts/run_benchmarks.sh {{n}}

# Quick single-engine benchmark (no comparison, skips deep recursion)
bench-fast n="2":
	@test -f out/boomkat || { echo "ERROR: out/boomkat not found — run: c3c build boomkat"; exit 1; }
	bash scripts/run_bench_fast.sh {{n}}

# Run a single benchmark file: `just bench-one benchmarks/bench_loop.js`
bench-one file n="3":
    @test -f out/boomkat || { echo "ERROR: out/boomkat not found"; exit 1; }
    ./out/boomkat {{file}}

# Run a single benchmark on original Duktape
bench-orig file:
	@test -f out/duktape || { echo "Building original Duktape..."; cc -O2 -o out/duktape benchmarks/duktape.c $(ls duktape/src-separate/*.c) -I.; }
	./out/duktape {{file}}

# ── Size & Memory Benchmarks ────────────────────────────────────────────────

# Measure binary sizes and peak RSS of all engines
bench-sizes:
	@echo "=== Engine Size & Memory Benchmark ==="
	@test -f out/boomkat || { echo "ERROR: out/boomkat not found — run: c3c build boomkat"; exit 1; }
	@test -f out/duktape || { echo "Building original Duktape..."; cc -O2 -o out/duktape benchmarks/duktape.c $(ls duktape/src-separate/*.c) -I.; }
	@test -f out/qjs || { echo "Building QuickJS..."; make -C quickjs qjs && cp quickjs/qjs out/; }
	bash scripts/run_sizes_bench.sh

# Rebuild boomkat and run size/memory benchmark
bench-sizes-rebuild:
	c3c build boomkat
	@test -f out/duktape || { echo "Building original Duktape..."; cc -O2 -o out/duktape benchmarks/duktape.c $(ls duktape/src-separate/*.c) -I.; }
	@test -f out/qjs || { echo "Building QuickJS..."; make -C quickjs qjs && cp quickjs/qjs out/; }
	bash scripts/run_sizes_bench.sh

# Measure peak RSS memory usage across engines
bench-memory:
	@test -f out/boomkat || { echo "ERROR: out/boomkat not found — run: c3c build boomkat"; exit 1; }
	@test -f out/duktape || { echo "Building original Duktape..."; cc -O2 -o out/duktape benchmarks/duktape.c $(ls duktape/src-separate/*.c) -I.; }
	@test -f out/qjs || { echo "Building QuickJS..."; make -C quickjs qjs && cp quickjs/qjs out/; }
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
