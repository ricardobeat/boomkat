#!/usr/bin/env bash
# Linux build / test / link-validation suite, run INSIDE the container image
# built from ci/linux/Dockerfile. Drive it from the host with `make linux-ci`.
#
# Every phase reports PASS/FAIL on its own line and the script exits non-zero if
# any phase failed, so a partial breakage cannot read as a green board.
#
# Usage (inside the container):  bash ci/linux/run.sh [phase ...]
# With no arguments every phase runs. Named phases run only those.

set -uo pipefail

cd "$(dirname "$0")/../.." || exit 1
ROOT="$PWD"
PREFIX="${PREFIX:-/tmp/jse-prefix}"
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
#include <jse.h>
#include <stdio.h>
#include <string.h>
int main(void) {
    jse_runtime rt;
    if (jse_open(&rt) != JSE_OK) return 1;
    const char *s = "6*7";
    jse_value v; double n = 0;
    if (jse_eval(rt, s, strlen(s), &v) != JSE_OK) return 1;
    jse_get_number(rt, v, &n);
    printf("%g\n", n);
    jse_value_free(rt, v); jse_close(rt);
    return n == 42.0 ? 0 : 1;
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
    [ -f out/jse_static.a ] && pass "out/jse_static.a" || fail "out/jse_static.a"
    timeout "$TIMEOUT" make shared 2>&1 | tail -2
    [ -f out/libjse.so ] && pass "out/libjse.so" || fail "out/libjse.so"
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
    if [ -f out/libjse.so ]; then
        ldd out/libjse.so
        if ldd out/libjse.so 2>&1 | grep -q 'not found'; then
            fail "libjse.so has unresolved deps"
        else
            pass "libjse.so deps all resolved"
        fi
    else
        skip "ldd libjse.so"
    fi

    timeout 120 just example-c-shared >/dev/null 2>&1
    if [ -x bindings/c/out/example-shared ]; then
        ldd bindings/c/out/example-shared
        if ldd bindings/c/out/example-shared 2>&1 | grep -q 'not found'; then
            fail "bindings/c/out/example-shared has unresolved deps"
        else
            pass "bindings/c/out/example-shared deps all resolved (links libjse.so via rpath)"
        fi
        ldd bindings/c/out/example-shared | grep -q 'libjse.so' \
            && pass "bindings/c/out/example-shared genuinely resolves libjse.so" \
            || fail "bindings/c/out/example-shared does not name libjse.so"
    else
        skip "ldd bindings/c/out/example-shared"
    fi

    say "5b. nm -D — exported jse_ symbols on the shared library"
    if [ -f out/libjse.so ]; then
        exported=$(nm -D --defined-only out/libjse.so | awk '$2 ~ /^[TDBRW]$/ {print $3}' | sort)
        jse_syms=$(printf '%s\n' "$exported" | grep -c '^jse_')
        printf '%s\n' "$exported" | grep '^jse_' | sed 's/^/  /'
        [ "$jse_syms" -ge 12 ] && pass "$jse_syms jse_ symbols exported (>= 12)" \
                               || fail "only $jse_syms jse_ symbols exported"

        # Everything the engine and its vendored C define is also exported: c3c
        # has no visibility control and no version script, so the whole module
        # graph (boomkat.*, lre_*, cr_*) lands in .dynsym. This is NOT a Linux
        # regression -- the macOS dylib exports ~2460 symbols for the same
        # reason -- so it is reported as a count, not failed on. What matters is
        # that the 12 documented jse_ entry points are all present.
        total_n=$(printf '%s\n' "$exported" | grep -c . || true)
        printf '  total exported symbols: %s (%s are jse_)\n' "$total_n" "$jse_syms"
        printf '  note: c3c exports the whole module graph; macOS does the same.\n'
        printf '  sample non-jse_ exports:\n'
        printf '%s\n' "$exported" | grep -v '^jse_' | head -5 | sed 's/^/    /'
    else
        skip "nm on libjse.so"
    fi

    say "5c. static archive links from plain cc"
    write_probe
    if cc -std=c99 -Iinclude /tmp/staticprobe.c out/jse_static.a -lm -ldl ${RT_LIB:+"$RT_LIB"} \
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
    if cc -std=c99 -Iinclude /tmp/staticprobe.c out/jse_static.a -lm -ldl \
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
    # On macOS, linking out/jse_static.a into a Zig-built executable segfaults in
    # __c3_runtime_startup before main, because Zig emits a second bogus
    # __mh_execute_header and the C3 runtime's constructor walk binds to it.
    # The ELF equivalent would be a mis-walked .init_array. Test it for real.
    # What the ELF equivalent of the macOS hazard would act on: the archive's
    # .init_array entries, which the C3 runtime's startup walk consumes.
    rm -rf /tmp/arx && mkdir -p /tmp/arx
    (cd /tmp/arx && ar x "$ROOT/out/jse_static.a" 2>/dev/null)
    printf '  .init_array sections in the archive members:\n'
    find /tmp/arx -name '*.o' 2>/dev/null | while read -r o; do
        n=$(readelf -S "$o" 2>/dev/null | grep -c 'init_array')
        [ "$n" -gt 0 ] && printf '    %s: %s .init_array section(s)\n' "$(basename "$o")" "$n"
    done | head -5

    mkdir -p /tmp/zigstatic && cd /tmp/zigstatic || exit 1
    cat > main.zig <<'EOF'
const std = @import("std");
const c = @cImport({ @cInclude("jse.h"); });

pub fn main() void {
    var rt: c.jse_runtime = undefined;
    if (c.jse_open(&rt) != c.JSE_OK) {
        std.debug.print("jse_open failed\n", .{});
        return;
    }
    const src = "6*7";
    var v: c.jse_value = undefined;
    if (c.jse_eval(rt, src, src.len, &v) != c.JSE_OK) {
        std.debug.print("eval failed\n", .{});
        c.jse_close(rt);
        return;
    }
    var n: f64 = 0;
    _ = c.jse_get_number(rt, v, &n);
    std.debug.print("zig static: {d}\n", .{n});
    c.jse_value_free(rt, v);
    c.jse_close(rt);
}
EOF
    zig_cmd=(zig build-exe main.zig -lc
             "-I$ROOT/include" "$ROOT/out/jse_static.a" -lm -ldl)
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
use std::os::raw::{c_char, c_double, c_int, c_void};
extern "C" {
    fn jse_open(out: *mut *mut c_void) -> c_int;
    fn jse_eval(rt: *mut c_void, src: *const c_char, len: usize, out: *mut u32) -> c_int;
    fn jse_get_number(rt: *mut c_void, v: u32, out: *mut c_double) -> c_int;
    fn jse_close(rt: *mut c_void);
}
fn main() {
    unsafe {
        let mut rt: *mut c_void = std::ptr::null_mut();
        assert_eq!(jse_open(&mut rt), 0, "jse_open");
        let s = b"6*7";
        let mut v: u32 = 0;
        assert_eq!(jse_eval(rt, s.as_ptr() as *const c_char, s.len(), &mut v), 0, "jse_eval");
        let mut n: c_double = 0.0;
        jse_get_number(rt, v, &mut n);
        println!("rust static: {}", n);
        jse_close(rt);
    }
}
EOF
    # rustc passes -nodefaultlibs, so libc is not implicitly available to the
    # archive; the C3 runtime's atexit hook needs it named explicitly.
    rustc_args=(src/main.rs -o ruststatic -L "$ROOT/out"
                -C link-arg="$ROOT/out/jse_static.a" -C link-arg=-lm -C link-arg=-ldl)
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

    if cc -std=c99 -I"$PREFIX/include" /tmp/staticprobe.c "$PREFIX/lib/libjse.a" \
           -lm -ldl ${RT_LIB:+"$RT_LIB"} -o /tmp/prefix_static 2>/tmp/ps.err; then
        o=$(cd /tmp && ./prefix_static)
        [ "$o" = "42" ] && pass "installed static: -I\$PREFIX/include + libjse.a runs ($o)" \
                        || fail "installed static printed '$o'"
    else
        head -5 /tmp/ps.err; fail "installed static link"
    fi

    if cc -std=c99 -I"$PREFIX/include" /tmp/staticprobe.c -L"$PREFIX/lib" -ljse \
           -Wl,-rpath,"$PREFIX/lib" -lm -ldl -o /tmp/prefix_shared 2>/tmp/psh.err; then
        o=$(cd /tmp && ./prefix_shared)
        [ "$o" = "42" ] && pass "installed shared: -ljse + rpath runs from any cwd ($o)" \
                        || fail "installed shared printed '$o'"
        ldd /tmp/prefix_shared | grep libjse | sed 's/^/  /'
    else
        head -5 /tmp/psh.err; fail "installed shared link"
    fi

    # Without an rpath the loader must fail; prove the rpath is load-bearing
    # rather than the library merely being found on the default search path.
    if cc -std=c99 -I"$PREFIX/include" /tmp/staticprobe.c -L"$PREFIX/lib" -ljse \
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
    [ -f "$PREFIX/include/jse.h" ] || timeout 120 make install PREFIX="$PREFIX" >/dev/null 2>&1

    # The working tree is bind-mounted from the macOS host, so any build cache
    # in it holds Mach-O artifacts. Every one of these caches is keyed in a way
    # that survives the platform change and then fails the link, so clear them.
    rm -rf bindings/zig/.zig-cache bindings/zig/zig-out \
           bindings/rust/target bindings/c/out/example bindings/c/out/example-shared

    # --- C example ---------------------------------------------------------
    if [ -d bindings/c ]; then
        # Exercise the install path: route the justfile at the staged prefix
        # populated by `make install PREFIX=$PREFIX` above, where the archive
        # is named libjse.a rather than the engine's own jse_static.a.
        if timeout 300 just example-c-static \
                JSE_INCDIR="$PREFIX/include" \
                JSE_LIBDIR="$PREFIX/lib" \
                JSE_STATIC_LIB="$PREFIX/lib/libjse.a" \
                >/tmp/c99.log 2>&1; then
            tail -6 /tmp/c99.log | sed 's/^/  /'
            pass "binding: C (static)"
        else
            tail -8 /tmp/c99.log | sed 's/^/  /'; fail "binding: C (static)"
        fi
        if timeout 300 just example-c-shared \
                JSE_INCDIR="$PREFIX/include" \
                JSE_LIBDIR="$PREFIX/lib" \
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
    if command -v cargo >/dev/null && [ -f bindings/rust/jse/Cargo.toml ]; then
        if timeout 900 cargo run --manifest-path bindings/rust/jse/Cargo.toml \
               --example hello_js >/tmp/rs.log 2>&1; then
            tail -8 /tmp/rs.log | sed 's/^/  /'; pass "binding: Rust"
        else
            tail -12 /tmp/rs.log | sed 's/^/  /'; fail "binding: Rust"
        fi
    else
        skip "binding: Rust"
    fi

    # --- C3 (native, does not go through the C ABI) ------------------------
    if timeout 600 make -s jse_example_c3 >/dev/null 2>&1 \
       || timeout 600 c3c build jse_example_c3 ${C3C_LDFLAGS:-} >/tmp/c3.log 2>&1 \
       || timeout 600 c3c build jse_example_c3 ${RT_LIB:+-z "$RT_LIB"} >/tmp/c3.log 2>&1; then
        if [ -x out/jse_example_c3 ] && timeout 120 ./out/jse_example_c3 >/tmp/c3run.log 2>&1; then
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
