#!/bin/bash
# Run the verbatim Rosetta Code suite.
# Usage: bash test/rosetta-verbatim/run.sh <engine_binary>
#
# Samples (<name>.js) are byte-identical copies of rosettacode.org code and are
# never edited. Each is driven either by a <name>.check.js assertion file (run
# through the ESM pipeline so it can import the sample) or, for samples whose
# behavior is what they print, by diffing stdout against <name>.expected.
ENGINE="${1:?Usage: $0 <engine_binary>}"
DIR="$(cd "$(dirname "$0")" && pwd)"
PASS=0; FAIL=0

for sample in "$DIR"/*.js; do
    name=$(basename "$sample" .js)
    case "$name" in _harness|*.check) continue ;; esac

    if [ -f "$DIR/$name.check.js" ]; then
        if out=$(timeout 10 "$ENGINE" --module "$DIR/$name.check.js" 2>&1); then
            echo "  ok  $name"; PASS=$((PASS+1))
        else
            echo "FAIL  $name"; echo "$out" | sed 's/^/        /' | head -5; FAIL=$((FAIL+1))
        fi
    elif [ -f "$DIR/$name.expected" ]; then
        if out=$(timeout 10 "$ENGINE" "$sample" 2>&1) && \
           diff -q <(printf '%s\n' "$out") "$DIR/$name.expected" >/dev/null; then
            echo "  ok  $name (output)"; PASS=$((PASS+1))
        else
            echo "FAIL  $name (output mismatch)"
            diff <(printf '%s\n' "$out") "$DIR/$name.expected" | sed 's/^/        /' | head -8
            FAIL=$((FAIL+1))
        fi
    else
        echo "SKIP  $name (no .check.js or .expected)"
    fi
done

echo ""
echo "rosetta-verbatim: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
