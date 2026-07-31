#!/bin/bash
# Run the verbatim Rosetta Code suite.
# Usage: bash test/rosetta-verbatim/run.sh <engine_binary>
#
# Samples (<name>.js) are byte-identical copies of rosettacode.org code and are
# never edited. Each is driven either by a <name>.check.js assertion file or,
# for samples whose behavior is what they print, by diffing stdout against
# <name>.expected.
#
# A check file is run by concatenating harness + sample + check into one script,
# which is how these samples were written to run: as plain scripts, with all
# top-level declarations sharing one scope. They are NOT ES modules and cannot
# be imported -- a module only exposes what it explicitly exports, and a
# verbatim sample has no export statements to add.
ENGINE="${1:?Usage: $0 <engine_binary>}"
DIR="$(cd "$(dirname "$0")" && pwd)"
TMP="${TMPDIR:-/tmp}/rosetta-verbatim.$$"
mkdir -p "$TMP"
trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0

# Strip the two-line provenance header (three, when a shebang pushes it down)
# so it does not land in the middle of the concatenated script.
sample_body() {
    if head -1 "$1" | grep -q '^#!'; then tail -n +4 "$1"; else tail -n +3 "$1"; fi
}

for sample in "$DIR"/*.js; do
    name=$(basename "$sample" .js)
    case "$name" in _harness|*.check) continue ;; esac

    if [ -f "$DIR/$name.check.js" ]; then
        joined="$TMP/$name.js"
        { cat "$DIR/_harness.js"; sample_body "$sample"; cat "$DIR/$name.check.js"; } > "$joined"
        if out=$(timeout 10 "$ENGINE" "$joined" 2>&1); then
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
