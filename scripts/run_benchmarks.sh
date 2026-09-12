#!/bin/bash
# Benchmark comparison runner for Boomkat vs other JS engines.
#
# Usage: ./scripts/run_benchmarks.sh [iterations]
#
# Runs all benchmarks on every available engine and prints a comparison table.
# Comparison-engine results are cached in out/bench_cache_<engine>.txt and
# reused across runs; delete those files (or `just bench-clear`) to re-run.
#
# Engines other than boomkat are optional: any whose binary is missing is
# skipped and simply omitted from the table.

set -euo pipefail

PROJ_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BENCH_DIR="$PROJ_DIR/benchmarks"
SHIM="$BENCH_DIR/shim.js"
ITERATIONS="${1:-3}"

TMPDIR_BENCH=$(mktemp -d)
trap 'rm -rf "$TMPDIR_BENCH"' EXIT

# ── Engine table ────────────────────────────────────────────────────────────
# key|label|binary|needs_shim
#
# needs_shim=1 prepends benchmarks/shim.js, which defines `print` in terms of
# console.log. Duktape and QuickJS ship `print` as a shell builtin; Boa and
# Kiesel do not, and without it they abort on the first call — Kiesel silently,
# with no stderr at all, which would otherwise be recorded as a very fast run.
ENGINES=(
    "boomkat|boomkat|$PROJ_DIR/out/boomkat|0"
    "duktape|Duktape|$PROJ_DIR/out/duktape|0"
    "qjs|QuickJS|$PROJ_DIR/out/qjs|0"
    "boa|Boa|$PROJ_DIR/out/boa|1"
    "kiesel|Kiesel|$PROJ_DIR/out/kiesel|1"
)

if [ ! -x "$PROJ_DIR/out/boomkat" ]; then
    echo "ERROR: C3 runner not found at $PROJ_DIR/out/boomkat"
    echo "Run: c3c build boomkat"
    exit 1
fi

# Engines actually present on this machine
avail_keys=(); avail_labels=(); avail_bins=(); avail_shim=()
for spec in "${ENGINES[@]}"; do
    IFS='|' read -r key label bin shim <<< "$spec"
    if [ -x "$bin" ]; then
        avail_keys+=("$key"); avail_labels+=("$label")
        avail_bins+=("$bin"); avail_shim+=("$shim")
    fi
done

bench_names=()
for f in "$BENCH_DIR"/bench_*.js; do
    bench_names+=("$(basename "$f" .js)")
done

# ── Cache helpers ───────────────────────────────────────────────────────────

cache_file() { echo "$PROJ_DIR/out/bench_cache_$1.txt"; }

cache_get() {
    local file="$1" key="$2"
    if [ -f "$file" ]; then grep "^${key}=" "$file" 2>/dev/null | cut -d= -f2 || true; fi
}

cache_set() {
    local file="$1" key="$2" val="$3"
    if [ -f "$file" ]; then
        grep -v "^${key}=" "$file" > "${file}.tmp" 2>/dev/null || true
        mv "${file}.tmp" "$file"
    fi
    echo "${key}=${val}" >> "$file"
}

all_cached() {
    local file="$1"
    [ -f "$file" ] || return 1
    for name in "${bench_names[@]}"; do
        [ -n "$(cache_get "$file" "$name")" ] || return 1
    done
    return 0
}

# ── Timing ──────────────────────────────────────────────────────────────────

# Milliseconds for one run. Returns the empty string if the engine exits
# non-zero, so a crashed or unsupported benchmark can never be mistaken for a
# fast one.
time_ms() {
    local start end
    start=$(date +%s%N)
    if ! "$@" >/dev/null 2>&1; then
        return 1
    fi
    end=$(date +%s%N)
    echo $(( (end - start) / 1000000 ))
}

echo "============================================================"
echo "  Boomkat — Benchmark Comparison"
echo "  $(date)"
echo "  Iterations per benchmark: $ITERATIONS"
echo "  Engines: ${avail_labels[*]}"
echo "============================================================"
echo ""

section=0
for idx in "${!avail_keys[@]}"; do
    key="${avail_keys[$idx]}"
    label="${avail_labels[$idx]}"
    bin="${avail_bins[$idx]}"
    shim="${avail_shim[$idx]}"
    section=$((section + 1))

    echo "------------------------------------------------------------"
    echo "  $section. $label (compile + execute)"
    echo "------------------------------------------------------------"

    # boomkat is the engine under test: always re-measured, never cached.
    cache=""
    if [ "$key" != "boomkat" ]; then
        cache=$(cache_file "$key")
        if all_cached "$cache"; then
            echo "  (using cached results — delete $cache to re-run)"
            for name in "${bench_names[@]}"; do
                val=$(cache_get "$cache" "$name")
                echo "$val" > "$TMPDIR_BENCH/${key}_$name"
                echo "  $name ... ${val}ms (cached)"
            done
            echo ""
            continue
        fi
    fi

    for name in "${bench_names[@]}"; do
        src="$BENCH_DIR/$name.js"
        if [ "$shim" = "1" ]; then
            src="$TMPDIR_BENCH/${key}_${name}_src.js"
            cat "$SHIM" "$BENCH_DIR/$name.js" > "$src"
        fi

        echo -n "  $name ... "
        total=0; count=0; failed=false
        for ((i=0; i<ITERATIONS; i++)); do
            if ! ms=$(time_ms "$bin" "$src"); then failed=true; break; fi
            total=$((total + ms)); count=$((count + 1))
        done

        if [ "$failed" = true ] || [ $count -eq 0 ]; then
            echo "FAILED"
            echo "N/A" > "$TMPDIR_BENCH/${key}_$name"
            if [ -n "$cache" ]; then cache_set "$cache" "$name" "N/A"; fi
        else
            avg=$((total / count))
            echo "$avg" > "$TMPDIR_BENCH/${key}_$name"
            if [ -n "$cache" ]; then cache_set "$cache" "$name" "$avg"; fi
            echo "${avg}ms"
        fi
    done
    echo ""
done

# ── Summary ─────────────────────────────────────────────────────────────────

echo "============================================================"
echo "  Results Summary"
echo "============================================================"
echo ""

printf "  %-26s" "Benchmark"
for label in "${avail_labels[@]}"; do printf " %11s" "$label(ms)"; done
printf "\n  "
printf '%.0s-' $(seq $((26 + 12 * ${#avail_labels[@]})))
printf "\n"

for name in "${bench_names[@]}"; do
    printf "  %-26s" "$name"
    for key in "${avail_keys[@]}"; do
        val=$(cat "$TMPDIR_BENCH/${key}_$name")
        printf " %11s" "$val"
    done
    printf "\n"
done

printf "  "
printf '%.0s-' $(seq $((26 + 12 * ${#avail_labels[@]})))
printf "\n\n"

# Per-engine totals over benchmarks every engine completed, so the comparison
# is over a common set rather than whatever each engine happened to finish.
common=()
for name in "${bench_names[@]}"; do
    ok=true
    for key in "${avail_keys[@]}"; do
        if [ "$(cat "$TMPDIR_BENCH/${key}_$name")" = "N/A" ]; then ok=false; fi
    done
    if [ "$ok" = true ]; then common+=("$name"); fi
done

if [ ${#common[@]} -gt 0 ]; then
    echo "  Totals over the ${#common[@]} benchmark(s) all engines completed,"
    echo "  relative to boomkat (>1.0 means slower than boomkat):"
    echo ""
    base=0
    for name in "${common[@]}"; do
        base=$((base + $(cat "$TMPDIR_BENCH/boomkat_$name")))
    done
    for idx in "${!avail_keys[@]}"; do
        key="${avail_keys[$idx]}"
        sum=0
        for name in "${common[@]}"; do
            sum=$((sum + $(cat "$TMPDIR_BENCH/${key}_$name")))
        done
        if [ "$base" -gt 0 ]; then
            ratio=$(echo "scale=2; $sum / $base" | bc 2>/dev/null || echo "?")
        else
            ratio="?"
        fi
        printf "  %-12s %8sms  %8sx\n" "${avail_labels[$idx]}" "$sum" "$ratio"
    done
    echo ""
fi
echo "============================================================"
