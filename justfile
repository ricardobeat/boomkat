# TinyDuck — common tasks

# ── Build ────────────────────────────────────────────────────────────────────

# Default build (VM test runner)
build:
    c3c build test_vm

# Build with NaN-boxing disabled (16-byte TVal, for 16-bit targets)
build-nonanbox:
    c3c -D NONANBOX build test_vm

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
