#!/usr/bin/env bash
# Build src/lib/temporal/tzdata_generated.c3 from canonical IANA tzdata.
#
# Usage:
#   scripts/tzdata/build.sh                    # auto-fetch IANA 2026c, zic -b fat, build
#   scripts/tzdata/build.sh --keep             # keep the IANA tarball + extracted dir
#   scripts/tzdata/build.sh --src-dir <path>   # use existing /path/containing/{africa,europe,...}
#   scripts/tzdata/build.sh --tzdata-url <URL> # use a different tzdata tarball
#
# The blob is committed (not regenerated per build), so this script is run
# once per IANA release and the result is checked in. The compiled file is
# ~400 KB; the binary grows by ~700 KB with the data embedded.
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
PROJECT_DIR=$(dirname $(dirname "$SCRIPT_DIR"))
BUILD_TMP=$(mktemp -d -t tzdata-build-XXXXXX)
IANA_URL="https://data.iana.org/time-zones/releases/tzdata2026c.tar.gz"

KEEP=0
SRC_DIR=""
TZDATA_URL="$IANA_URL"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --keep) KEEP=1; shift ;;
        --src-dir) SRC_DIR="$2"; shift 2 ;;
        --tzdata-url) TZDATA_URL="$2"; shift 2 ;;
        *) echo "unknown arg: $1" >&2; exit 1 ;;
    esac
done

cd "$BUILD_TMP"

if [[ -z "$SRC_DIR" ]]; then
    TARBALL="$BUILD_TMP/tzdata.tar.gz"
    echo "Downloading $TZDATA_URL"
    if ! curl --connect-timeout 10 --max-time 120 -sL "$TZDATA_URL" -o "$TARBALL"; then
        echo "FAIL: could not download $TZDATA_URL" >&2
        echo "Use --src-dir to point at an existing IANA tzdata source directory" >&2
        exit 1
    fi
    tar -xzf "$TARBALL"
    SRC_DIR="$BUILD_TMP"
fi

mkdir -p "$BUILD_TMP/zic-out"
echo "Compiling with zic -b fat (POSIX rules expanded to year $RULES_UP_TO)"
zic -d "$BUILD_TMP/zic-out" -b fat \
    africa antarctica asia australasia europe northamerica southamerica \
    etcetera backward

echo "Generating C3 source..."
python3 "$SCRIPT_DIR/build_tzdata.py" --zoneinfo-dir "$BUILD_TMP/zic-out"

if [[ $KEEP -eq 0 ]]; then
    rm -rf "$BUILD_TMP"
else
    echo "Kept build dir: $BUILD_TMP"
fi

echo "Done. Output: $PROJECT_DIR/src/lib/temporal/tzdata_generated.c3"
