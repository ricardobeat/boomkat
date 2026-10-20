#!/usr/bin/env bash
# Build src/lib/temporal/tzdata_generated.c3 from canonical IANA tzdata.
#
# Usage:
#   scripts/tzdata/build.sh                      # auto-fetch the default release below
#   scripts/tzdata/build.sh --version 2024a     # fetch a specific IANA release
#   scripts/tzdata/build.sh --keep               # keep the IANA tarball + extracted dir
#   scripts/tzdata/build.sh --src-dir <path>     # use existing /path/containing/{africa,europe,...}
#   scripts/tzdata/build.sh --tzdata-url <URL>   # use a fully custom tarball URL
#
# --version is the usual knob: test262's Temporal timezone expectations are
# pinned to a dataset, so regenerating against a newer IANA release can shift
# offsets that the suite asserts on. Pass the release the suite expects.
#
# The generated file is committed (not regenerated per build), so this script
# is run once per IANA release and the result is checked in.
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
PROJECT_DIR=$(dirname $(dirname "$SCRIPT_DIR"))
BUILD_TMP=$(mktemp -d -t tzdata-build-XXXXXX)
# Default IANA release. Override with --version (preferred) or --tzdata-url.
#
# Pinned to the release the committed tzdata_generated.c3 was built from, so a
# plain rerun reproduces the checked-in data instead of silently upgrading it.
# test262's Temporal tests assert concrete UTC offsets for DST-sensitive zones,
# so bumping this can change suite results — do it deliberately and rerun the
# suite, don't let it drift.
TZDATA_VERSION="2026c"

KEEP=0
SRC_DIR=""
TZDATA_URL=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --keep) KEEP=1; shift ;;
        --src-dir) SRC_DIR="$2"; shift 2 ;;
        --version) TZDATA_VERSION="$2"; shift 2 ;;
        --tzdata-url) TZDATA_URL="$2"; shift 2 ;;
        *) echo "unknown arg: $1" >&2; exit 1 ;;
    esac
done

# --tzdata-url wins if given; otherwise derive the URL from --version.
if [[ -z "$TZDATA_URL" ]]; then
    TZDATA_URL="https://data.iana.org/time-zones/releases/tzdata${TZDATA_VERSION}.tar.gz"
fi

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

SOURCES=("$SRC_DIR/africa" "$SRC_DIR/antarctica" "$SRC_DIR/asia" "$SRC_DIR/australasia"
    "$SRC_DIR/europe" "$SRC_DIR/northamerica" "$SRC_DIR/southamerica"
    "$SRC_DIR/etcetera" "$SRC_DIR/backward")
# slim is what is encoded; fat (rules expanded to 2037) is the reference the
# generator checks the slim data plus footer rules against.
echo "Compiling with zic -b slim and -b fat"
mkdir -p "$BUILD_TMP/zic-slim" "$BUILD_TMP/zic-fat"
zic -d "$BUILD_TMP/zic-slim" -b slim "${SOURCES[@]}"
zic -d "$BUILD_TMP/zic-fat" -b fat "${SOURCES[@]}"

echo "Generating C3 source..."
python3 "$SCRIPT_DIR/build_tzdata.py" --slim-dir "$BUILD_TMP/zic-slim" \
    --fat-dir "$BUILD_TMP/zic-fat" \
    --tzdata-version "$TZDATA_VERSION" \
    --output "$PROJECT_DIR/src/lib/temporal/tzdata_generated.c3"

if [[ $KEEP -eq 0 ]]; then
    rm -rf "$BUILD_TMP"
else
    echo "Kept build dir: $BUILD_TMP"
fi

echo "Done. Output: $PROJECT_DIR/src/lib/temporal/tzdata_generated.c3"
