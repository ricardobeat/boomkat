#!/usr/bin/env bash
# Linux build / test / link-validation suite, run INSIDE the container image
# built from scripts/linux/arm64/Dockerfile. Drive it from the host with `make linux-ci`.
#
# Every phase reports PASS/FAIL on its own line and the script exits non-zero if
# any phase failed, so a partial breakage cannot read as a green board.
#
# Usage (inside the container):  bash scripts/linux/arm64/run.sh [phase ...]
# With no arguments every phase runs. Named phases run only those.

set -uo pipefail

cd "$(dirname "$0")/../../.." || exit 1
ROOT="$PWD"
PREFIX="${PREFIX:-/tmp/boomkat-prefix}"
RESULTS=()
FAILED=0

# Tight per-phase timeout: a hang must surface as a failure, not eat the run.
TIMEOUT="${TIMEOUT:-600}"

say()  { printf '\n\033[1m=== %s ===\033[0m\n' "$*"; }
pass() { RESULTS+=("PASS  $*"); printf '  \033[32mPASS\033[0m  %s\n' "$*"; }
fail() { RESULTS+=("FAIL  $*"); FAILED=1; printf '  \033[31mFAIL\033[0m  %s\n' "$*"; }
skip() { RESULTS+=("SKIP  $*"); printf '  \033[33mSKIP\033[0m  %s\n' "$*"; }

# The compiler-rt archive carrying __muloti4; see the Makefile comment.
RT_LIB=$(ls /usr/lib/llvm-*/lib/clang/*/lib/linux/libclang_rt.builtins-"$(uname -m)".a 2>/dev/null | head -1)

want() {
    [ ${#PHASES[@]} -eq 0 ] && return 0
    local p
    for p in "${PHASES[@]}"; do [ "$p" = "$1" ] && return 0; done
    return 1
}

# The C probe every link check compiles. Written by a function so each phase can
# run standalone rather than depending on an earlier phase having created it.
write_probe() {
    cat > /tmp/staticprobe.c <<'EOF'
#include <boomkat.h>
#include <stdio.h>
int main(void) {
    bk_ctx ctx = bk_open();
    if (!ctx) return 1;
    const char *s = "6*7";
    bk_value v = bk_eval_str(ctx, s);
    if (!v) return 1;
    double n = 0;
    if (bk_read_number(ctx, v, &n) != BK_OK) return 1;
    printf("%g\n", n);
    bk_free(ctx, v);
    bk_close(ctx);
    return 0;
}
EOF
}

PHASES=("$@")

# ---------------------------------------------------------------------------
say "environment"
printf 'arch      : %s\n' "$(uname -m)"
printf 'kernel    : %s\n' "$(uname -sr)"
printf 'c3c       : %s\n' "$(c3c --version 2>&1 | awk '/Compiler Version/{print $4}')"
printf 'llvm      : %s\n' "$(c3c --version 2>&1 | awk '/LLVM version/{print $3}')"
printf 'cc        : %s\n' "$(cc --version | head -1)"
printf 'compiler-rt: %s\n' "${RT_LIB:-<none found>}"

# ---------------------------------------------------------------------------
if want build; then
    say "1. build the engine (c3c build boomkat)"
    if timeout "$TIMEOUT" make boomkat 2>&1 | grep -viE 'warning|^ *[0-9]+:|^ *\^+ *$' | tail -5; then
        [ -x out/boomkat ] && pass "engine binary built" || fail "engine binary missing"
    else
        fail "engine build"
    fi
fi

# ---------------------------------------------------------------------------
if want tests; then
    say "2. engine test suite (bash test/run_local.sh)"
    if [ ! -x out/boomkat ]; then
        skip "test suite (no engine binary)"
    else
        suite_log=$(mktemp)
        timeout 1800 bash test/run_local.sh >"$suite_log" 2>&1
        suite_rc=$?
        grep -E 'passed|matched reference|^FAIL' "$suite_log" | tail -20
        [ $suite_rc -eq 0 ] && pass "test suite (exit 0)" || fail "test suite (exit $suite_rc)"
        rm -f "$suite_log"
    fi
fi

# ---------------------------------------------------------------------------
if want test262; then
    say "2b. test262 zero-fail gate (bash scripts/test262_gate.sh)"
    # The runner reads test files from the test262/ submodule. When the working
    # tree is bind-mounted from the host, the submodule must be checked out
    # there; a fresh clone in the container needs `git submodule update --init`.
    if [ ! -d test262/test ]; then
        skip "test262 (submodule test262/ not checked out)"
    else
        # Build the batch runner in-container so it matches this platform, then
        # run the same gate CI and `just test262-gate` use.
        if timeout "$TIMEOUT" make out/test262_runner 2>&1 | tail -3; then
            t262_log=$(mktemp)
            timeout 3600 bash scripts/test262_gate.sh >"$t262_log" 2>&1
            t262_rc=$?
            grep -E '^Overall \(raw\):|GATE (PASSED|FAILED)|run [0-9]' "$t262_log" | tail -20
            [ $t262_rc -eq 0 ] && pass "test262 gate (0 fail)" || fail "test262 gate (exit $t262_rc)"
            rm -f "$t262_log"
        else
            fail "test262 runner build"
        fi
    fi
fi

# ---------------------------------------------------------------------------
if want libs; then
    say "3. build both libraries (make lib / make shared)"
    timeout "$TIMEOUT" make lib 2>&1 | tail -2
    [ -f out/boomkat.a ] && pass "out/boomkat.a" || fail "out/boomkat.a"
    timeout "$TIMEOUT" make shared 2>&1 | tail -2
    [ -f out/boomkat.so ] && pass "out/boomkat.so" || fail "out/boomkat.so"
fi

# ---------------------------------------------------------------------------
if want smoke; then
    say "4. make smoke (must print 42)"
    smoke_out=$(timeout 120 make smoke 2>&1 | tail -1)
    printf '  output: %s\n' "$smoke_out"
    [ "$smoke_out" = "42" ] && pass "smoke prints 42" || fail "smoke printed '$smoke_out'"
fi

# ---------------------------------------------------------------------------
if want link; then
    say "5a. ldd — shared library and a linked executable"
    if [ -f out/boomkat.so ]; then
        ldd out/boomkat.so
        if ldd out/boomkat.so 2>&1 | grep -q 'not found'; then
            fail "boomkat.so has unresolved deps"
        else
            pass "boomkat.so deps all resolved"
        fi
    else
        skip "ldd boomkat.so"
    fi

    timeout 120 just example-c-shared >/dev/null 2>&1
    if [ -x bindings/c/out/example-shared ]; then
        ldd bindings/c/out/example-shared
        if ldd bindings/c/out/example-shared 2>&1 | grep -q 'not found'; then
            fail "bindings/c/out/example-shared has unresolved deps"
        else
            pass "bindings/c/out/example-shared deps all resolved (links boomkat.so via rpath)"
        fi
        ldd bindings/c/out/example-shared | grep -q 'boomkat.so' \
            && pass "bindings/c/out/example-shared genuinely resolves boomkat.so" \
            || fail "bindings/c/out/example-shared does not name boomkat.so"
    else
        skip "ldd bindings/c/out/example-shared"
    fi

    say "5b. nm -D -- exported bk_ symbols on the shared library"
    if [ -f out/boomkat.so ]; then
        exported=$(nm -D --defined-only out/boomkat.so | awk '$2 ~ /^[TDBRW]$/ {print $3}' | sort)
        bk_syms=$(printf '%s\n' "$exported" | grep -c '^bk_')
        total_n=$(printf '%s\n' "$exported" | grep -c . || true)
        printf '  total exported symbols: %s (%s are bk_)\n' "$total_n" "$bk_syms"
        # The version script bounds the export set to exactly the header's
        # BK_API surface: no engine internals, nothing for ELF interposition
        # to grab (the re_exec collision this replaced is history).
        expected=$(grep -c '^bk_' out/boomkat.exports 2>/dev/null || echo 0)
        if [ "$total_n" -eq "$expected" ] && [ "$expected" -gt 0 ]; then
            pass "export list enforced: $total_n symbols, all bk_"
        else
            fail "export list not enforced ($total_n exported, $expected declared)"
        fi
    else
        skip "nm on boomkat.so"
    fi

    say "5c. static archive links from plain cc"
    write_probe
    if cc -std=c99 -Iinclude /tmp/staticprobe.c out/boomkat.a -lm -ldl ${RT_LIB:+"$RT_LIB"} \
           -o /tmp/staticprobe 2>/tmp/staticprobe.err; then
        out=$(/tmp/staticprobe)
        [ "$out" = "42" ] && pass "plain cc + static archive runs (printed $out)" \
                          || fail "static probe printed '$out'"
    else
        head -5 /tmp/staticprobe.err
        fail "plain cc could not link the static archive"
    fi

    # Does the archive link WITHOUT the compiler-rt archive? A GCC-only host has
    # no __muloti4, so this decides what an embedder must be told to pass. It is
    # reported either way rather than failed: needing compiler-rt is a genuine
    # platform constraint, not a defect the suite can fix.
    if cc -std=c99 -Iinclude /tmp/staticprobe.c out/boomkat.a -lm -ldl \
           -o /tmp/staticprobe_nort 2>/tmp/nort.err; then
        pass "static archive links without compiler-rt (libgcc suffices)"
    else
        printf '  missing: %s\n' \
            "$(grep -oE "undefined reference to \`[^']+'" /tmp/nort.err | sort -u | tr '\n' ' ')"
        pass "static archive requires compiler-rt (documented: embedders must pass it)"
    fi
fi

# ---------------------------------------------------------------------------
if want initarray; then
    say "5d. C3-runtime init hazard: foreign linker drives the final link"
    # On macOS, linking out/boomkat.a into a Zig-built executable segfaults in
    # __c3_runtime_startup before main, because Zig emits a second bogus
    # __mh_execute_header and the C3 runtime's constructor walk binds to it.
    # The ELF equivalent would be a mis-walked .init_array. Test it for real.
    # What the ELF equivalent of the macOS hazard would act on: the archive's
    # .init_array entries, which the C3 runtime's startup walk consumes.
    rm -rf /tmp/arx && mkdir -p /tmp/arx
    (cd /tmp/arx && ar x "$ROOT/out/boomkat.a" 2>/dev/null)
    printf '  .init_array sections in the archive members:\n'
    find /tmp/arx -name '*.o' 2>/dev/null | while read -r o; do
        n=$(readelf -S "$o" 2>/dev/null | grep -c 'init_array')
        [ "$n" -gt 0 ] && printf '    %s: %s .init_array section(s)\n' "$(basename "$o")" "$n"
    done | head -5

    mkdir -p /tmp/zigstatic && cd /tmp/zigstatic || exit 1
    cat > main.zig <<'EOF'
const std = @import("std");
const c = @cImport({ @cInclude("boomkat.h"); });

pub fn main() void {
    const ctx = c.bk_open() orelse return;
    defer c.bk_close(ctx);
    const src = "6*7";
    const v = c.bk_eval_str(ctx, src);
    if (v == 0) return;
    var n: f64 = 0;
    if (c.bk_read_number(ctx, v, &n) != c.BK_OK) return;
    std.debug.print("zig static: {d}\n", .{n});
    c.bk_free(ctx, v);
}
EOF
    zig_cmd=(zig build-exe main.zig -lc
             "-I$ROOT/include" "$ROOT/out/boomkat.a" -lm -ldl)
    [ -n "$RT_LIB" ] && zig_cmd+=("$RT_LIB")
    if timeout 300 "${zig_cmd[@]}" 2>/tmp/zigstatic.err; then
        zout=$(timeout 60 ./main 2>&1); zrc=$?
        printf '  run: rc=%d out=[%s]\n' "$zrc" "$zout"
        if [ $zrc -eq 0 ] && printf '%s' "$zout" | grep -q '42'; then
            pass "STATIC archive links AND runs from Zig on Linux (no init hazard)"
        else
            fail "Zig static link built but crashed/misbehaved (rc=$zrc)"
        fi
    else
        head -10 /tmp/zigstatic.err | sed 's/^/    /'
        fail "Zig could not link the static archive"
    fi
    cd "$ROOT" || exit 1

    # Same question from Rust, whose linker driver is also not c3c.
    mkdir -p /tmp/ruststatic/src && cd /tmp/ruststatic || exit 1
    cat > Cargo.toml <<'EOF'
[package]
name = "ruststatic"
version = "0.0.0"
edition = "2021"
[[bin]]
name = "ruststatic"
path = "src/main.rs"
EOF
    cat > src/main.rs <<'EOF'
use std::os::raw::{c_char, c_double, c_ulonglong, c_void};
extern "C" {
    fn bk_open() -> *mut c_void;
    fn bk_close(ctx: *mut c_void);
    fn bk_eval(ctx: *mut c_void, src: *const c_char, len: usize) -> c_ulonglong;
    fn bk_read_number(ctx: *mut c_void, v: c_ulonglong, out: *mut c_double) -> c_int;
    fn bk_free(ctx: *mut c_void, v: c_ulonglong);
}
fn main() {
    unsafe {
        let ctx = bk_open();
        assert!(!ctx.is_null(), "bk_open");
        let s = b"6*7";
        let v = bk_eval(ctx, s.as_ptr() as *const c_char, s.len());
        assert_ne!(v, 0, "bk_eval");
        let mut n: c_double = 0.0;
        bk_read_number(ctx, v, &mut n);
        println!("rust static: {}", n);
        bk_free(ctx, v);
        bk_close(ctx);
    }
}
EOF
    # rustc passes -nodefaultlibs, so libc is not implicitly available to the
    # archive; the C3 runtime's atexit hook needs it named explicitly.
    rustc_args=(src/main.rs -o ruststatic -L "$ROOT/out"
                -C link-arg="$ROOT/out/boomkat.a" -C link-arg=-lm -C link-arg=-ldl)
    [ -n "$RT_LIB" ] && rustc_args+=(-C link-arg="$RT_LIB")
    rustc_args+=(-C link-arg=-lc)
    if timeout 300 rustc "${rustc_args[@]}" 2>/tmp/ruststatic.err; then
        rout=$(timeout 60 ./ruststatic 2>&1); rrc=$?
        printf '  run: rc=%d out=[%s]\n' "$rrc" "$rout"
        if [ $rrc -eq 0 ] && printf '%s' "$rout" | grep -q '42'; then
            pass "STATIC archive links AND runs from rustc on Linux"
        else
            fail "rustc static link built but crashed (rc=$rrc)"
        fi
    else
        head -10 /tmp/ruststatic.err | sed 's/^/    /'
        fail "rustc could not link the static archive"
    fi
    cd "$ROOT" || exit 1
fi

# ---------------------------------------------------------------------------
if want install; then
    say "5e. make install + compile against the installed prefix"
    write_probe
    rm -rf "$PREFIX"
    timeout 120 make install PREFIX="$PREFIX" 2>&1 | tail -3
    ls -la "$PREFIX/lib" "$PREFIX/include" 2>&1 | sed 's/^/  /'

    if cc -std=c99 -I"$PREFIX/include" /tmp/staticprobe.c "$PREFIX/lib/boomkat.a" \
           -lm -ldl ${RT_LIB:+"$RT_LIB"} -o /tmp/prefix_static 2>/tmp/ps.err; then
        o=$(cd /tmp && ./prefix_static)
        [ "$o" = "42" ] && pass "installed static: -I\$PREFIX/include + boomkat.a runs ($o)" \
                        || fail "installed static printed '$o'"
    else
        head -5 /tmp/ps.err; fail "installed static link"
    fi

    if cc -std=c99 -I"$PREFIX/include" /tmp/staticprobe.c -L"$PREFIX/lib" -lboomkat \
           -Wl,-rpath,"$PREFIX/lib" -lm -ldl -o /tmp/prefix_shared 2>/tmp/psh.err; then
        o=$(cd /tmp && ./prefix_shared)
        [ "$o" = "42" ] && pass "installed shared: -lboomkat + rpath runs from any cwd ($o)" \
                        || fail "installed shared printed '$o'"
        ldd /tmp/prefix_shared | grep boomkat | sed 's/^/  /'
    else
        head -5 /tmp/psh.err; fail "installed shared link"
    fi

    # Without an rpath the loader must fail; prove the rpath is load-bearing
    # rather than the library merely being found on the default search path.
    if cc -std=c99 -I"$PREFIX/include" /tmp/staticprobe.c -L"$PREFIX/lib" -lboomkat \
           -lm -ldl -o /tmp/prefix_norpath 2>/dev/null; then
        if (cd /tmp && ./prefix_norpath >/dev/null 2>&1); then
            printf '  note: runs without rpath (loader found it anyway)\n'
        else
            pass "no-rpath build fails at load time, as documented (LD_LIBRARY_PATH needed)"
        fi
        LD_LIBRARY_PATH="$PREFIX/lib" bash -c 'cd /tmp && ./prefix_norpath' >/dev/null 2>&1 \
            && pass "LD_LIBRARY_PATH rescues the no-rpath build" \
            || fail "LD_LIBRARY_PATH did not rescue the no-rpath build"
    fi
fi

# ---------------------------------------------------------------------------
if want bindings; then
    say "6. language bindings"

    # The C99 example builds against an installed prefix, so make sure one
    # exists even when the `install` phase was not selected.
    [ -f "$PREFIX/include/boomkat.h" ] || timeout 120 make install PREFIX="$PREFIX" >/dev/null 2>&1

    # The working tree is bind-mounted from the macOS host, so any build cache
    # in it holds Mach-O artifacts. Every one of these caches is keyed in a way
    # that survives the platform change and then fails the link, so clear them.
    rm -rf bindings/zig/.zig-cache bindings/zig/zig-out \
           bindings/rust/target bindings/c/out/example bindings/c/out/example-shared

    # --- C example ---------------------------------------------------------
    if [ -d bindings/c ]; then
        # Exercise the install path: route the justfile at the staged prefix
        # populated by `make install PREFIX=$PREFIX` above, where the archive
        # is named boomkat.a rather than the engine's own boomkat.a.
        if timeout 300 just example-c-static \
                BK_INCDIR="$PREFIX/include" \
                BK_LIBDIR="$PREFIX/lib" \
                BK_STATIC_LIB="$PREFIX/lib/boomkat.a" \
                >/tmp/c99.log 2>&1; then
            tail -6 /tmp/c99.log | sed 's/^/  /'
            pass "binding: C (static)"
        else
            tail -8 /tmp/c99.log | sed 's/^/  /'; fail "binding: C (static)"
        fi
        if timeout 300 just example-c-shared \
                BK_INCDIR="$PREFIX/include" \
                BK_LIBDIR="$PREFIX/lib" \
                >/tmp/c99s.log 2>&1; then
            pass "binding: C (shared)"
        else
            tail -8 /tmp/c99s.log | sed 's/^/  /'; fail "binding: C (shared)"
        fi
    else
        skip "binding: C (bindings/c absent)"
    fi

    # --- Python ------------------------------------------------------------
    if command -v python3 >/dev/null; then
        if timeout 300 python3 bindings/python/example.py >/tmp/py.log 2>&1; then
            tail -8 /tmp/py.log | sed 's/^/  /'; pass "binding: Python (ctypes)"
        else
            tail -8 /tmp/py.log | sed 's/^/  /'; fail "binding: Python (ctypes)"
        fi
    else
        skip "binding: Python"
    fi

    # --- Ruby --------------------------------------------------------------
    if command -v ruby >/dev/null; then
        if timeout 300 just example-ruby >/tmp/rb.log 2>&1; then
            tail -8 /tmp/rb.log | sed 's/^/  /'; pass "binding: Ruby (fiddle)"
        else
            tail -8 /tmp/rb.log | sed 's/^/  /'; fail "binding: Ruby (fiddle)"
        fi
    else
        skip "binding: Ruby"
    fi

    # --- Zig ---------------------------------------------------------------
    # .zig-cache is bind-mounted from the host and may hold macOS-built
    # artifacts, which make the Linux build fail on a stale manifest.
    if command -v zig >/dev/null && [ -f bindings/zig/build.zig ]; then
        rm -rf bindings/zig/.zig-cache bindings/zig/zig-out
        if (cd bindings/zig && timeout 600 zig build run) >/tmp/zig.log 2>&1; then
            tail -8 /tmp/zig.log | sed 's/^/  /'; pass "binding: Zig (shared)"
        else
            tail -10 /tmp/zig.log | sed 's/^/  /'; fail "binding: Zig (shared)"
        fi
    else
        skip "binding: Zig"
    fi

    # --- Rust --------------------------------------------------------------
    if command -v cargo >/dev/null && [ -f bindings/rust/boomkat/Cargo.toml ]; then
        if timeout 900 cargo run --manifest-path bindings/rust/boomkat/Cargo.toml \
               --example hello_js >/tmp/rs.log 2>&1; then
            tail -8 /tmp/rs.log | sed 's/^/  /'; pass "binding: Rust"
        else
            tail -12 /tmp/rs.log | sed 's/^/  /'; fail "binding: Rust"
        fi
    else
        skip "binding: Rust"
    fi

    # --- C3 (native, does not go through the C ABI) ------------------------
    if timeout 600 make -s boomkat_example_c3 >/dev/null 2>&1 \
       || timeout 600 c3c build boomkat_example_c3 ${C3C_LDFLAGS:-} >/tmp/c3.log 2>&1 \
       || timeout 600 c3c build boomkat_example_c3 ${RT_LIB:+-z "$RT_LIB"} >/tmp/c3.log 2>&1; then
        if [ -x out/boomkat_example_c3 ] && timeout 120 ./out/boomkat_example_c3 >/tmp/c3run.log 2>&1; then
            tail -8 /tmp/c3run.log | sed 's/^/  /'; pass "binding: C3 (native)"
        else
            tail -8 /tmp/c3run.log 2>/dev/null | sed 's/^/  /'; fail "binding: C3 (native, run)"
        fi
    else
        tail -6 /tmp/c3.log 2>/dev/null | sed 's/^/  /'; fail "binding: C3 (native, build)"
    fi
fi

# ---------------------------------------------------------------------------
say "summary"
printf '%s\n' "${RESULTS[@]}"
printf '\n%d phase result(s), overall: %s\n' "${#RESULTS[@]}" \
    "$([ $FAILED -eq 0 ] && echo PASS || echo FAIL)"
exit $FAILED
