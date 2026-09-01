#!/bin/bash
# src/lib/temporal/ must build and run without the engine.
#
# The calendrical layer -- civil date arithmetic, ISO 8601 parsing, the tz
# database, instant arithmetic, and the Duration value type with its unit and
# rounding vocabulary -- is deliberately free of engine types, so it can be
# reused and tested on its own. Nothing enforces that but this check:
# a single `import boomkat::heap` added for convenience would re-couple it, and
# the engine build would still pass because the engine has those symbols.
#
# The check copies the library to a scratch directory with NO engine sources
# present and compiles a driver against it. If any file imports an engine
# module, the compile fails there with an unresolved import.
#
# Instant arithmetic is int128 rather than the engine's HBigInt: the spec's
# range is +/-8.64e21 ns, which needs 74 bits, so int128 carries it with room to
# spare. src/builtins/temporal.c3 owns the BigInt conversion at the boundary,
# since that is a language binding rather than a calendrical concern.
#
# Usage: bash scripts/check_temporal_standalone.sh
set -euo pipefail

PROJ_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cp "$PROJ_DIR"/src/lib/temporal/*.c3 "$WORK/"

cat > "$WORK/main.c3" <<'EOF'
module standalone_check;
import boomkat::lib::temporal;
import std::io;

fn int main() {
    int fails = 0;

    // Civil date arithmetic.
    long d = temporal::epoch_days_from_civil(2026, 8, 30);
    if (d != 20695) { io::printfn("FAIL epoch_days: %d != 20695", d); fails++; }

    // Instant arithmetic, pure int128.
    int128 base  = (int128)d * 86400 * 1000000000;
    int128 later = temporal::instant_add(base, (int128)3600 * 1000000000);
    if (temporal::instant_cmp(base, later) != -1) { io::printn("FAIL instant_cmp"); fails++; }
    if (temporal::instant_sub(later, base) != (int128)3600 * 1000000000) {
        io::printn("FAIL instant_sub"); fails++;
    }
    if (!temporal::instant_in_range(later)) { io::printn("FAIL in_range"); fails++; }
    // One nanosecond past the spec's limit must be rejected.
    if (temporal::instant_in_range(temporal::INSTANT_MAX_NS + 1)) {
        io::printn("FAIL in_range accepted an out-of-range value"); fails++;
    }

    // Timezone database: Amsterdam is CEST (+2h) at the end of August.
    int off = temporal::tzdb_offset_for_zone_at("Europe/Amsterdam", (long)(base / 1000000000));
    if (off != 7200) { io::printfn("FAIL tz offset: %d != 7200", off); fails++; }

    // Duration value type: validity, balancing, and the exact division that
    // total() needs. Pure integer arithmetic -- no calendar, no engine.
    temporal::DurationParts d1 = {};
    d1.hours = 1; d1.minutes = 30;
    if (temporal::duration_to_time_ns(d1) != (int128)5400 * 1000000000) {
        io::printn("FAIL duration_to_time_ns"); fails++;
    }
    if (!temporal::is_valid_duration(&d1)) { io::printn("FAIL is_valid_duration"); fails++; }
    // Mixed signs are not a valid duration.
    temporal::DurationParts d2 = {};
    d2.hours = 1; d2.minutes = -1;
    if (temporal::is_valid_duration(&d2)) { io::printn("FAIL is_valid_duration mixed signs"); fails++; }
    // 90 minutes decomposes to 1h30m at largestUnit = hour.
    temporal::DurationParts d3;
    temporal::decompose_ns(5400L * 1000000000L, temporal::TemporalUnit.HOUR, &d3);
    if (d3.hours != 1 || d3.minutes != 30) {
        io::printfn("FAIL decompose_ns: %dh%dm", d3.hours, d3.minutes); fails++;
    }
    // The unit vocabulary and its rounding primitives.
    if (temporal::unit_ns_divisor(temporal::TemporalUnit.SECOND) != 1000000000L) {
        io::printn("FAIL unit_ns_divisor"); fails++;
    }
    if (!temporal::is_cal_unit(temporal::TemporalUnit.MONTH) ||
         temporal::is_cal_unit(temporal::TemporalUnit.DAY)) {
        io::printn("FAIL is_cal_unit"); fails++;
    }
    if (temporal::round_long_ns(1500L, 1000L, temporal::TemporalRoundMode.HALF_EXPAND) != 2000L) {
        io::printn("FAIL round_long_ns half-expand"); fails++;
    }
    if (temporal::round_long_ns(1500L, 1000L, temporal::TemporalRoundMode.TRUNC) != 1000L) {
        io::printn("FAIL round_long_ns trunc"); fails++;
    }

    if (fails == 0) { io::printn("temporal standalone: OK"); return 0; }
    io::printfn("temporal standalone: %d FAILED", fails);
    return 1;
}
EOF

cd "$WORK"
if ! out=$(c3c compile-run ./*.c3 2>&1); then
    echo "FAIL: src/lib/temporal does not build without the engine"
    printf '%s\n' "$out" | grep -E "Error:" | head -10 | sed 's/^/      | /'
    exit 1
fi

if ! printf '%s\n' "$out" | grep -q "temporal standalone: OK"; then
    echo "FAIL: standalone temporal library built but its assertions failed"
    printf '%s\n' "$out" | grep -E "^FAIL|standalone" | sed 's/^/      | /'
    exit 1
fi

echo "Temporal standalone: builds and runs with no engine imports"
