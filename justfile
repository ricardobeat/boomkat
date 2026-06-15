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

# Rebuild and measure memory usage
bench-memory-compare:
    @echo "=== Building ==="
    c3c build test_vm
    @echo ""
    @echo "=== MEMORY USAGE ==="
    @bash scripts/run_memory_bench.sh
