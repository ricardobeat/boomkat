#!/bin/bash
# Sample a workload, then disassemble each hot symbol to explain WHY it is hot.
#
# Usage: ./scripts/perf_triage.sh <script.js> [seconds]
#
# `sample` answers "where does time go", which is usually the part you already
# know. The expensive question is "why does this handler cost what it does",
# and that lives in the disassembly. This joins the two.
#
# What the columns mean:
#
#   instrs  Instruction count between the symbol and its first `ret`. Compare
#           against peers: a threaded handler doing a guarded load should be in
#           the same range as th_addi (~34). Several times that is a signal.
#   frame   The symbol opens with stp/ldp pairs saving callee-saved registers.
#           On a per-instruction handler that prologue is paid on EVERY
#           dispatch. th_getvar carried one solely because of a cold-path call
#           and assembled to 163 instructions; removing it dropped it to 91.
#   calls   Non-inlined calls. On a small handler a single one is usually what
#           forces the frame -- the `bl` target names the culprit.
#
# A frame is not automatically a bug: th_getglobal keeps one deliberately
# because bailing out instead measured worse. The table finds candidates; only
# an interleaved A/B (scripts/perf_diff.sh) decides.

set -euo pipefail

PROJ_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BIN="${PERF_TRIAGE_BIN:-$PROJ_DIR/out/boomkat}"
SCRIPT_JS="${1:-}"
SECONDS_ARG="${2:-4}"
TOP="${PERF_TRIAGE_TOP:-12}"

[ -n "$SCRIPT_JS" ] || { sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }
[ -f "$SCRIPT_JS" ] || { echo "no such script: $SCRIPT_JS" >&2; exit 1; }
[ -x "$BIN" ]       || { echo "no binary at $BIN — run: just build boomkat" >&2; exit 1; }

command -v sample >/dev/null || { echo "ERROR: needs macOS \`sample\`" >&2; exit 1; }
command -v otool  >/dev/null || { echo "ERROR: needs \`otool\`" >&2; exit 1; }

echo "binary:   $BIN"
echo "workload: $SCRIPT_JS"
echo "load:     $(uptime | sed 's/.*averages*: *//' | awk '{print $1}')"
echo

RAW="$(mktemp "${TMPDIR:-/tmp}/triage.XXXXXX")"
DIS="$(mktemp "${TMPDIR:-/tmp}/triagedis.XXXXXX")"
trap 'rm -f "$RAW" "$DIS"' EXIT

"$BIN" "$SCRIPT_JS" >/dev/null 2>&1 &
PID=$!
sample "$PID" "$SECONDS_ARG" -mayDie >"$RAW" 2>/dev/null || true
wait "$PID" 2>/dev/null || true

# Disassemble once; scanning a ~200MB binary per symbol is far too slow.
otool -tv "$BIN" >"$DIS" 2>/dev/null

SYMS="$(sed -n '/Sort by top of stack/,/^$/p' "$RAW" \
        | grep -oE 'boomkat[a-zA-Z0-9_.]+ +\(in [^)]*\) +[0-9]+' \
        | sed 's/ *(in [^)]*) */ /' | head -"$TOP")"

[ -n "$SYMS" ] || { echo "no boomkat frames sampled (workload too short? raise the seconds argument)"; exit 0; }

printf "%-42s %8s %8s %6s %6s\n" "symbol" "samples" "instrs" "frame" "calls"
printf "%-42s %8s %8s %6s %6s\n" "------------------------------------------" "--------" "--------" "------" "------"

while read -r sym count; do
    [ -n "$sym" ] || continue
    body="$(awk -v s="_${sym}:" '$0 ~ "^"s {f=1} f {print} f && /\tret/ {exit}' "$DIS")"
    if [ -z "$body" ]; then
        printf "%-42s %8s %8s %6s %6s\n" "${sym#boomkat.}" "$count" "-" "-" "-"
        continue
    fi
    instrs=$(echo "$body" | wc -l | tr -d ' ')
    frame=$(echo "$body" | head -3 | grep -c 'stp' || true)
    calls=$(echo "$body" | grep -cE '	(bl|blr)	' || true)
    [ "$frame" -gt 0 ] && frame="YES" || frame="leaf"
    printf "%-42s %8s %8s %6s %6s\n" "${sym#boomkat.}" "$count" "$instrs" "$frame" "$calls"
done <<< "$SYMS"

echo
echo "For any symbol with a frame and few instructions, the forcing call is:"
echo "  otool -tv $BIN | awk '/_boomkat.vm.NAME:/,/ret/' | grep -E '\\s(bl|blr)\\s'"
echo "Confirm any change with an interleaved A/B: scripts/perf_diff.sh <ref>"
