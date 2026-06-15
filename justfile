# TinyDuck — common tasks

# ── Build ────────────────────────────────────────────────────────────────────

# Rebuild test_vm (default build target) — includes RegExp
build:
    c3c build test_vm

# Build with NaN-boxing disabled (16-byte TVal, for 16-bit targets)
build-nonanbox:
    c3c -D NONANBOX build test_vm

# Build without RegExp support (no libregexp linked)
build-noregexp:
    c3c build test_vm_noregexp

# Build the minimal engine (heap init only, no test runner)
bench:
    c3c build minimal

# Cross-compile for RISC-V 64-bit (Linux, static, musl)
build-riscv64:
    c3c --target linux-riscv64 --single-module=yes -Oz build test_vm
    zig cc -target riscv64-linux-musl -static -Oz riscv_crt/crt.c build/obj/linux-riscv64/duktape.bytecode.o -o out/test_vm_rv64 -lm
    @file out/test_vm_rv64

# Clean build artifacts
clean:
    c3c clean

# ── Run ──────────────────────────────────────────────────────────────────────

# Run a single JS file
run file="test/hello.js":
    c3c build test_vm
    ./out/test_vm {{file}}

# ── Tests ────────────────────────────────────────────────────────────────────

# Run the rosetta suite
test:
    c3c build test_vm
    bash test/rosetta/run.sh ./out/test_vm

# List available commands
list:
    @just --list

# ── Memory Benchmarks ────────────────────────────────────────────────────────

# Measure peak RSS memory usage across engines
bench-memory:
    @echo "=== Memory Usage Benchmark ==="
    @test -f out/test_vm || { echo "ERROR: out/test_vm not found — run: just build"; exit 1; }
    @bash scripts/run_memory_bench.sh

# Full performance benchmark (binary size, time, memory)
bench-perf label="bytecode":
    c3c build test_vm
    c3c build test_vm_noregexp
    c3c build minimal
    bash scripts/run_benchmarks.sh {{label}}

# Rebuild and measure memory usage
bench-memory-compare:
    @echo "=== Building ==="
    c3c build test_vm
    @echo ""
    @echo "=== MEMORY USAGE ==="
    @bash scripts/run_memory_bench.sh
