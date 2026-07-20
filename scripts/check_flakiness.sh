#!/usr/bin/env bash
# Flakiness check: run a JS test many times and report how often it crashes/times out.
# Usage: bash scripts/check_flakiness.sh <js-file> [iterations]
set -u
file="${1:?usage: check_flakiness.sh <file> [iters]}"
iters="${2:-50}"
timeout="${TIMEOUT:-5}"
total=0
crash=0
timeout_ct=0
hang=0
ok=0
for i in $(seq 1 "$iters"); do
    total=$((total + 1))
    start=$(date +%s)
    timeout "$timeout" ./out/duktape_c3 "$file" > /dev/null 2>&1
    rc=$?
    end=$(date +%s)
    elapsed=$((end - start))
    if [ "$rc" -eq 124 ]; then
        timeout_ct=$((timeout_ct + 1))
    elif [ "$rc" -ne 0 ]; then
        crash=$((crash + 1))
    elif [ "$elapsed" -ge "$timeout" ]; then
        hang=$((hang + 1))
    else
        ok=$((ok + 1))
    fi
done
echo "iters=$total ok=$ok crash=$crash timeout=$timeout_ct hang=$hang"
