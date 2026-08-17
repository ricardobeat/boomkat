#!/usr/bin/env bash
#
# test262_delta.sh — Run test262 suite, record results, and show pass/fail deltas.
#
# Usage:
#   ./scripts/test262_delta.sh
#
# This script:
#   1. Runs the full test262 suite via scripts/run_test262.py
#   2. Parses per-phase pass/fail/skip counts from the output
#   3. Saves results to test262_results/latest.json with a timestamp
#   4. Compares with test262_results/previous.json (if it exists) and prints a delta report
#   5. Rotates latest.json → previous.json for the next comparison
#
# The script is idempotent — safe to run multiple times.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
RESULTS_DIR="$PROJECT_DIR/test262_results"
LATEST_JSON="$RESULTS_DIR/latest.json"
PREVIOUS_JSON="$RESULTS_DIR/previous.json"

mkdir -p "$RESULTS_DIR"

# Temporary file for raw runner output
TEMP_RAW="$RESULTS_DIR/.raw_output.tmp"
# Cleanup on exit
cleanup() { rm -f "$TEMP_RAW"; }
trap cleanup EXIT

# ---------------------------------------------------------------------------
# 1. Run the full test262 suite
# ---------------------------------------------------------------------------
echo "=== test262 Phase Delta Report ==="
echo ""
echo "Running full test262 suite (this may take 20+ minutes)..."
echo ""

set +e
python3 "$SCRIPT_DIR/run_test262.py" 2>&1 | tee "$TEMP_RAW"
RUN_EXIT=${PIPESTATUS[0]}
set -e

if [ "$RUN_EXIT" -ne 0 ]; then
    echo ""
    echo "Warning: test262 run exited with code $RUN_EXIT (partial results may be saved)" >&2
fi

TIMESTAMP=$(date "+%Y-%m-%d %H:%M:%S")

# ---------------------------------------------------------------------------
# 2. Parse output and save latest.json
# ---------------------------------------------------------------------------
echo ""
echo "Parsing results..."

python3 - "$TEMP_RAW" "$TIMESTAMP" "$LATEST_JSON" <<'PYEOF'
import json, re, sys

raw_path, timestamp, outpath = sys.argv[1], sys.argv[2], sys.argv[3]

with open(raw_path) as f:
    text = f.read()

phases = []
overall_pass = overall_fail = overall_skip = 0

for line in text.split('\n'):
    # Parse phase data lines, current runner format:
    #   "Phase 0-1: Label | total | pass | fail | skip | CE:expected-parse | ..."
    # The runner prints the CE columns after the skip count, so take the first
    # five |-separated fields. The header "Phase | Total | ..." also starts
    # with "Phase " but has no colon, so the ": " guard excludes it.
    if line.startswith('Phase ') and ': ' in line:
        parts = [p.strip() for p in line.split('|')]
        if len(parts) >= 5:
            label = parts[0]
            p_total = int(parts[1])
            p_pass  = int(parts[2])
            p_fail  = int(parts[3])
            p_skip  = int(parts[4])
            phases.append({
                "label": label,
                "total": p_total,
                "pass": p_pass,
                "fail": p_fail,
                "skip": p_skip,
            })
            overall_pass += p_pass
            overall_fail += p_fail
            overall_skip += p_skip

    # Parse overall line (overrides phase-summed totals when present, e.g.
    # "Overall (raw): 18302 pass / 123 fail (99.3%)"); the "(raw)" qualifier
    # came with the CE breakdown columns.
    m = re.match(r'^Overall(?:\s*\(raw\))?:\s*(\d+)\s+pass\s+/\s+(\d+)\s+fail', line)
    if m:
        overall_pass = int(m.group(1))
        overall_fail = int(m.group(2))

    # Parse skipped line ("Skipped: 456 tests" — only printed when skip > 0)
    m = re.match(r'^Skipped:\s*(\d+)', line)
    if m:
        overall_skip = int(m.group(1))

overall_total = overall_pass + overall_fail + overall_skip

data = {
    "timestamp": timestamp,
    "phases": phases,
    "overall": {
        "pass":  overall_pass,
        "fail":  overall_fail,
        "skip":  overall_skip,
        "total": overall_total,
    },
}

with open(outpath, 'w') as f:
    json.dump(data, f, indent=2)
    f.write('\n')

sys.stderr.write(
    f"Saved: {len(phases)} phases, "
    f"{overall_pass} pass, {overall_fail} fail, {overall_skip} skipped\n"
)
PYEOF

# ---------------------------------------------------------------------------
# 3. Compare with previous if it exists
# ---------------------------------------------------------------------------
if [ -f "$PREVIOUS_JSON" ]; then
    echo ""
    python3 - "$PREVIOUS_JSON" "$LATEST_JSON" <<'PYEOF'
import json, sys

prev_path, curr_path = sys.argv[1], sys.argv[2]

with open(prev_path) as f:
    prev = json.load(f)
with open(curr_path) as f:
    curr = json.load(f)

prev_phases = {p['label']: p for p in prev['phases']}
curr_phases = {p['label']: p for p in curr['phases']}

# Union of all labels, preserving insertion order (Python 3.7+)
seen = set()
all_labels = []
for lbl in list(prev_phases.keys()) + list(curr_phases.keys()):
    if lbl not in seen:
        seen.add(lbl)
        all_labels.append(lbl)

# Build abbreviated labels: "Phase X-Y: Label" → "X-Y Label"
def abbreviate(label):
    if label.startswith("Phase "):
        rest = label[len("Phase "):]
        if ": " in rest:
            idx = rest.index(": ")
            rest = rest[:idx] + " " + rest[idx + 2:]
        return rest
    return label

abbrevs = {lbl: abbreviate(lbl) for lbl in all_labels}

# Column width — at least 15, padded to fit all abbreviations, capped at 60
label_width = max(len(abbrevs[l]) for l in all_labels) if all_labels else 15
label_width = max(label_width, 15)
label_width = min(label_width, 60)

# Helper to format delta with + sign for positive
def fmt_delta(d):
    if d > 0:
        return f"+{d}"
    elif d < 0:
        return str(d)
    return "0"

# ── Print report ────────────────────────────────────────────────────────
print("test262 Phase Delta Report")
print("=" * (label_width + 35))
print(f"Date: {curr['timestamp']}")
print()

# Table header
header = f"{'Phase':<{label_width}} | {'Before':>6} | {'After':>6} | {'Delta':>6}"
sep    = "-" * label_width + "-|--------|--------|-------"
print(header)
print(sep)

for label in all_labels:
    p = prev_phases.get(label, {})
    c = curr_phases.get(label, {})

    p_pass = p.get('pass', 0)
    c_pass = c.get('pass', 0)

    delta = c_pass - p_pass

    abbrev = abbrevs[label]
    if len(abbrev) > label_width:
        abbrev = abbrev[:label_width - 3] + "..."

    print(f"{abbrev:<{label_width}} | {p_pass:>6} | {c_pass:>6} | {fmt_delta(delta):>6}")

print()

# Overall summary
p_over  = prev['overall']['pass']
c_over  = curr['overall']['pass']
p_fail  = prev['overall']['fail']
c_fail  = curr['overall']['fail']
p_skip  = prev['overall']['skip']
c_skip  = curr['overall']['skip']
p_total = prev['overall']['total']
c_total = curr['overall']['total']

d_pass  = c_over - p_over
d_fail  = c_fail - p_fail
d_skip  = c_skip - p_skip
d_total = c_total - p_total

print(f"Overall pass: {p_over} → {c_over} ({fmt_delta(d_pass)})")
print(f"Overall fail: {p_fail} → {c_fail} ({fmt_delta(d_fail)})")
if d_skip != 0 or p_skip != 0:
    print(f"Overall skip: {p_skip} → {c_skip} ({fmt_delta(d_skip)})")
print(f"Overall total: {p_total} → {c_total} ({fmt_delta(d_total)})")
PYEOF
else
    echo ""
    echo "No previous results found — this is the first run."
    echo "A baseline has been created for future comparisons."
fi

# ---------------------------------------------------------------------------
# 4. Rotate to previous.json for next comparison
# ---------------------------------------------------------------------------
cp "$LATEST_JSON" "$PREVIOUS_JSON"
echo ""
echo "Results saved to $LATEST_JSON"
echo "Baseline updated at $PREVIOUS_JSON"
