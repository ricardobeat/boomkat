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

# Build the CLI script runner
build-cli:
    c3c build tinyduck_cli

# Build and run a JS file with the CLI
cli file:
    @just build-cli
    ./out/tinyduck_cli {{file}}

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
run file='test/hello.js':
    @just build-test
    ./out/tinyduck_test {{file}}

# Debug build and run a single JS file
run-debug file='test/hello.js':
    @just build-test-debug
    ./out/tinyduck_test_debug {{file}}

# Debug build and dump bytecode only (no execution)
dump file='test/hello.js':
    @just build-test-debug
    ./out/tinyduck_test_debug {{file}}

# ── Tests ────────────────────────────────────────────────────────────────────

# Build test runner and run the rosetta suite
test:
    @just build-test
    bash test/rosetta/run.sh ./out/tinyduck_test

# Build debug test runner and run the rosetta suite
test-debug:
    @just build-test-debug
    bash test/rosetta/run.sh ./out/tinyduck_test_debug

# List available commands
list:
    @just --list
