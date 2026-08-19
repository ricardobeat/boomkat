#!/bin/bash
# Interleaved A/B benchmark comparison with a load guard.
#
# Usage: ./scripts/perf_diff.sh <git-ref> [script.js ...]
#        ./scripts/perf_diff.sh HEAD~1                  # all benchmarks/
#        ./scripts/perf_diff.sh main /tmp/mycase.js     # specific scripts
#
# Builds <git-ref> into a scratch worktree, then alternates runs between that
# binary and out/boomkat, reporting best-of-N for each.
#
# Why it works this way:
#
#   - INTERLEAVED, never all-A-then-all-B. Machine load drifts over minutes;
#     running one binary to completion and then the other attributes that drift
#     to the code change. This cost real time in practice: a "62ms regression"
#     and a "10% win" both evaporated when re-measured alternating.
#   - LOAD GUARD. Above LOAD_MAX the numbers are worthless. Refuses rather
#     than printing something misleading; override with -f if you only need a
#     rough relative signal.
#   - BEST-OF-N, not mean. Noise is one-sided: interference makes a run slower,
#     never faster, so the minimum is the cleanest estimate of true cost.
#   - NOISE FLOOR. Differences under NOISE_PCT are reported as "="; a number
#     you should not act on should not look like a result.
#
# Never uses `git stash` -- the stash stack is shared across worktrees in this
# repo and collides with parallel agents.

set -euo pipefail

PROJ_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RUNS="${PERF_DIFF_RUNS:-5}"
LOAD_MAX="${PERF_DIFF_LOAD_MAX:-3.0}"
NOISE_PCT="${PERF_DIFF_NOISE_PCT:-3}"
FORCE=0

usage() { sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

while [ $# -gt 0 ]; do
    case "$1" in
        -f|--force) FORCE=1; shift ;;
        -n|--runs)  RUNS="$2"; shift 2 ;;
        -h|--help)  usage 0 ;;
        --) shift; break ;;
        -*) echo "unknown flag: $1" >&2; usage 1 ;;
        *) break ;;
    esac
done

[ $# -ge 1 ] || usage 1
BASE_REF="$1"; shift

load_now() { uptime | sed 's/.*averages*: *//' | awk '{print $1}'; }

check_load() {
    local l; l=$(load_now)
    if [ "$FORCE" = 1 ]; then
        echo "load $l (forced; treat numbers as relative only)"
        return
    fi
    if awk -v l="$l" -v m="$LOAD_MAX" 'BEGIN{exit !(l>m)}'; then
        cat >&2 <<EOF
ERROR: load average is $l, above the $LOAD_MAX threshold.

Timings taken now would be dominated by scheduling noise. Wait for the
machine to settle, or re-run with -f if you only need a rough signal.

Currently heaviest:
$(ps aux | awk '$3>25 {printf "  %.0f%% %s\n", $3, $11}' | head -5)
EOF
        exit 2
    fi
    echo "load $l (under $LOAD_MAX)"
}

# --- build the baseline into a scratch worktree -------------------------------
WT="$(mktemp -d "${TMPDIR:-/tmp}/perfdiff.XXXXXX")"
cleanup() { git -C "$PROJ_DIR" worktree remove --force "$WT" >/dev/null 2>&1 || true; rm -rf "$WT"; }
trap cleanup EXIT

BASE_SHA="$(git -C "$PROJ_DIR" rev-parse --short "$BASE_REF")"
echo "baseline: $BASE_REF ($BASE_SHA)"
echo "current:  $(git -C "$PROJ_DIR" rev-parse --short HEAD)$(git -C "$PROJ_DIR" diff --quiet || echo ' + uncommitted')"

git -C "$PROJ_DIR" worktree add --detach "$WT" "$BASE_SHA" >/dev/null 2>&1

# quickjs/, libregexp/, duktape/ and test/libcorpus/ are gitignored vendor
# trees, so a fresh worktree has none of them and the C sources fail to
# compile. Link them from the main checkout rather than copying.
for d in quickjs libregexp duktape test/libcorpus; do
    [ -e "$PROJ_DIR/$d" ] && ln -sfn "$PROJ_DIR/$d" "$WT/$d" 2>/dev/null || true
done

echo -n "building baseline... "
( cd "$WT" && c3c build boomkat >/dev/null 2>&1 ) || { echo "FAILED"; exit 1; }
echo "ok"

BASE_BIN="$WT/out/boomkat"
NEW_BIN="$PROJ_DIR/out/boomkat"
[ -x "$NEW_BIN" ] || { echo "ERROR: $NEW_BIN missing — run: just build boomkat" >&2; exit 1; }

# --- pick workloads -----------------------------------------------------------
if [ $# -gt 0 ]; then
    SCRIPTS=("$@")
else
    SCRIPTS=()
    for f in "$PROJ_DIR"/benchmarks/bench_*.js; do SCRIPTS+=("$f"); done
fi

check_load
echo "best of $RUNS, interleaved"
echo

printf "%-24s %10s %10s %9s\n" "workload" "baseline" "current" "delta"
printf "%-24s %10s %10s %9s\n" "------------------------" "----------" "----------" "---------"

run_once() { { /usr/bin/time -p "$1" "$2" >/dev/null; } 2>&1 | awk '/^real/{print $2}'; }

REGRESSED=0
for s in "${SCRIPTS[@]}"; do
    name="$(basename "$s" .js | sed 's/^bench_//')"
    b_best=""; n_best=""
    for _ in $(seq "$RUNS"); do
        # Alternate within the iteration so drift hits both sides equally.
        b=$(run_once "$BASE_BIN" "$s") || continue
        n=$(run_once "$NEW_BIN"  "$s") || continue
        b_best=$(awk -v a="$b" -v c="${b_best:-999}" 'BEGIN{print (a<c)?a:c}')
        n_best=$(awk -v a="$n" -v c="${n_best:-999}" 'BEGIN{print (a<c)?a:c}')
    done
    [ -n "$b_best" ] || { printf "%-24s %10s\n" "$name" "(failed)"; continue; }

    delta=$(awk -v b="$b_best" -v n="$n_best" -v t="$NOISE_PCT" 'BEGIN{
        if (b==0) { print "n/a"; exit }
        p=(n-b)/b*100
        if (p<-t)      printf "%.0f%% faster", -p
        else if (p>t)  printf "%.0f%% SLOWER", p
        else           printf "="
    }')
    case "$delta" in *SLOWER*) REGRESSED=1 ;; esac
    printf "%-24s %9ss %9ss %9s\n" "$name" "$b_best" "$n_best" "$delta"
done

echo
echo "load after: $(load_now)"
[ "$REGRESSED" = 0 ] || echo "note: at least one workload regressed beyond the ${NOISE_PCT}% noise floor."
