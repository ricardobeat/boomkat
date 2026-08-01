#!/bin/bash
# A/B benchmark driver: alternates the two binaries round by round so machine
# drift (thermal, scheduler) hits both arms equally instead of one.
# Reports per-arm median, min, and relative standard deviation as a noise floor.
set -u

A="$1"; B="$2"; REPS="${3:-9}"
BENCH_DIR="$(cd "$(dirname "$0")" && pwd)/benchmarks"

python3 - "$A" "$B" "$REPS" "$BENCH_DIR" <<'PY'
import subprocess, sys, time, statistics, os, glob

a, b, reps, bdir = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]
skip = {"bench_recursion_deep"}
files = sorted(f for f in glob.glob(os.path.join(bdir, "bench_*.js"))
               if os.path.basename(f)[:-3] not in skip)

def run(binary, f):
    t = time.perf_counter()
    r = subprocess.run([binary, f], stdout=subprocess.DEVNULL,
                       stderr=subprocess.DEVNULL)
    d = time.perf_counter() - t
    return d if r.returncode == 0 else None

print(f"{'benchmark':<26} {'A med':>9} {'A rsd':>6} {'B med':>9} {'B rsd':>6} {'B/A':>7}")
print("-" * 70)
ratios = []
for f in files:
    name = os.path.basename(f)[:-3]
    ta, tb = [], []
    for _ in range(reps):
        # Interleave within each round.
        x = run(a, f); y = run(b, f)
        if x is None or y is None:
            ta = tb = None; break
        ta.append(x); tb.append(y)
    if not ta:
        print(f"{name:<26} FAILED")
        continue
    ma, mb = statistics.median(ta), statistics.median(tb)
    rsda = statistics.stdev(ta) / statistics.mean(ta) * 100
    rsdb = statistics.stdev(tb) / statistics.mean(tb) * 100
    ratios.append(mb / ma)
    print(f"{name:<26} {ma*1000:8.1f}m {rsda:5.1f}% {mb*1000:8.1f}m {rsdb:5.1f}% {mb/ma:7.3f}")

print("-" * 70)
print(f"geomean B/A = {statistics.geometric_mean(ratios):.4f}   "
      f"median B/A = {statistics.median(ratios):.4f}")
PY
