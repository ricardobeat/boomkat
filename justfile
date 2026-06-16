# TinyDuck — common tasks

# ── Build ────────────────────────────────────────────────────────────────────

# Build the tinyduck engine (default)
build:
    c3c build tinyduck

# Build with NaN-boxing disabled (16-byte TVal, for 16-bit targets)
build-nonanbox:
    c3c -D NONANBOX build tinyduck

# Build the test runner (includes RegExp)
build-test:
    c3c build tinyduck_test

# Build the test runner without RegExp support
build-test-noregexp:
    c3c build tinyduck_test_noregexp

# Cross-compile for RISC-V 64-bit (Linux, static, musl)
build-riscv64:
    c3c --target linux-riscv64 --single-module=yes -Oz build tinyduck_test
    zig cc -target riscv64-linux-musl -static -Oz riscv_crt/crt.c build/obj/linux-riscv64/tinyduck_test.o -o out/tinyduck_test_rv64 -lm
    @file out/tinyduck_test_rv64

# Build debug test runner (includes instruction trace, crash dumps, etc.)
build-test-debug:
    c3c build tinyduck_test_debug

# Build debug engine
build-debug:
    c3c build tinyduck_debug

# Clean build artifacts
clean:
    c3c clean

# ── Run ──────────────────────────────────────────────────────────────────────

# Build test runner and run a single JS file
run file="test/hello.js":
    c3c build tinyduck_test
    ./out/tinyduck_test {{file}}

# Debug build and run a single JS file (with all debug flags)
run-debug file="test/hello.js":
    c3c build tinyduck_test_debug
    ./out/tinyduck_test_debug --trace-vm {{file}}

# Debug build and dump bytecode only (no execution)
dump file="test/hello.js":
    c3c build tinyduck_test_debug
    ./out/tinyduck_test_debug --compile-only {{file}}

# ── Tests ────────────────────────────────────────────────────────────────────

# Build test runner and run the rosetta suite
test:
    c3c build tinyduck_test
    bash test/rosetta/run.sh ./out/tinyduck_test

# Build debug test runner and run the rosetta suite
test-debug:
    c3c build tinyduck_test_debug
    bash test/rosetta/run.sh ./out/tinyduck_test_debug

# List available commands
list:
    @just --list

# ── Benchmarks ───────────────────────────────────────────────────────────────

# Measure peak RSS memory usage across engines
bench-memory:
    @echo "=== Memory Usage Benchmark ==="
    @test -f out/tinyduck_test || { echo "ERROR: out/tinyduck_test not found — run: just build-test"; exit 1; }
    @bash scripts/run_memory_bench.sh

# Full performance benchmark (binary size, time, memory)
bench-perf label="bytecode":
    c3c build tinyduck_test
    c3c build tinyduck_test_noregexp
    c3c build tinyduck
    bash scripts/run_benchmarks.sh {{label}}

# Rebuild and measure memory usage
bench-memory-compare:
    @echo "=== Building ==="
    c3c build tinyduck_test
    @echo ""
    @echo "=== MEMORY USAGE ==="
    @bash scripts/run_memory_bench.sh
