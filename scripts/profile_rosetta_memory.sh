#!/bin/bash
# Profile peak RSS for each rosetta test individually.
# Usage: bash scripts/profile_rosetta_memory.sh
set -euo pipefail

PROJ_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RUNNER="$PROJ_DIR/out/boomkat"
ROSETTA_DIR="$PROJ_DIR/test/engine"

if [ ! -f "$RUNNER" ]; then
    echo "ERROR: $RUNNER not found. Run: c3c build boomkat"
    exit 1
fi

measure_rss() {
    local script="$1"
    local output
    output=$(/usr/bin/time -l "$RUNNER" "$script" 2>&1 >/dev/null) || true
    local rss_bytes
    rss_bytes=$(echo "$output" | grep -i "maximum resident set size" | grep -o '[0-9][0-9]*' | head -1)
    if [ -z "$rss_bytes" ]; then echo "0"; return; fi
    echo $(( rss_bytes / 1024 ))
}

echo "=== Rosetta Memory Profile ($(date)) ==="
echo ""
printf "%-30s %10s %s\n" "Test" "RSS(KB)" "Category"
echo "--------------------------------------------------------------"

total=0
count=0
for f in "$ROSETTA_DIR"/*.js; do
    name=$(basename "$f" .js)
    rss=$(measure_rss "$f")
    total=$((total + rss))
    count=$((count + 1))

    # Categorize by workload type
    case "$name" in
        ackermann|fibonacci|factorial|gcd|primality|collatz|sieve)
            cat="math/recursion" ;;
        bubble_sort|binary_search|linear_search|quicksort)
            cat="sort/search" ;;
        array_splice|matrix_*|reduce_sum)
            cat="arrays" ;;
        string_methods|reverse_string|palindrome|unicode_strings)
            cat="strings" ;;
        closures|currying|mutual_recursion|map_function|apply_call)
            cat="functions/closures" ;;
        arguments_object|this_binding)
            cat="args/this" ;;
        prototypes|define_property|object_keys|object_merge)
            cat="objects/prototypes" ;;
        json_roundtrip|regexp|parseint_radix)
            cat="builtins" ;;
        date_basics|error_types|do_while|switch_case|try_catch|type_coercion|typeof_instanceof|fizzbuzz|hoisting)
            cat="language" ;;
        *)
            cat="general" ;;
    esac

    printf "%-30s %7d KB  %s\n" "$name" "$rss" "$cat"
done

avg=$((total / count))
echo "--------------------------------------------------------------"
printf "%-30s %7d KB  (average of %d tests)\n" "AVERAGE" "$avg" "$count"
