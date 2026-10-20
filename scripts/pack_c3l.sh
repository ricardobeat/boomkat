#!/usr/bin/env bash
# Assemble a boomkat.c3l library package from the engine source tree.
#
# Usage:  scripts/pack_c3l.sh [--link]
#
# Default mode copies all files into dist/boomkat.c3l/ (distributable).
# Pass --link to create dist/boomkat.link.c3l/ with symlinks instead.
#
# The resulting .c3l can be consumed by any C3 project:
#
#     c3c build my_app --libdir <parent-of-c3l> --lib boomkat
#
# or added to a project.json "dependencies" list.

set -euo pipefail
cd "$(dirname "$0")/.."

MODE="copy"
C3L_DIR="dist/boomkat.c3l"

if [[ "${1:-}" == "--link" ]]; then
    MODE="symlink"
    C3L_DIR="dist/boomkat.link.c3l"
fi

# --- clean slate ---------------------------------------------------------------
rm -rf "$C3L_DIR"
mkdir -p "$C3L_DIR"

# --- link or copy a path into the .c3l ----------------------------------------
link_or_copy() {
    local src="$1"
    local dst="$C3L_DIR/$1"
    mkdir -p "$(dirname "$dst")"
    if [[ "$MODE" == "copy" ]]; then
        cp -R "$src" "$dst"
    else
        ln -s "../../$src" "$dst"
    fi
}

# --- engine C3 sources + C dependencies ---------------------------------------
link_or_copy "src"
link_or_copy "libregexp"
# Only the four vendored dtoa/cutils files, not the 45 MB upstream quickjs
# checkout: that tree is a benchmark engine fetched on demand, and nothing in a
# package build reads it.
link_or_copy "vendor"

# --- manifest.json -------------------------------------------------------------
cat > "$C3L_DIR/manifest.json" <<'MANIFEST'
{
    "provides": "boomkat",
    "sources": [
        "src"
    ],
    "c-sources": [
        "libregexp/libregexp.c",
        "libregexp/libunicode.c",
        "libregexp/re_wrapper.c",
        "libregexp/unicode_wrapper.c",
        "vendor/dtoa/cutils.c",
        "vendor/dtoa/dtoa.c",
        "src/dtoa_wrapper.c",
        "src/date_math.c",
        "src/native_stack.c",
        "src/sysmem.c"
    ],
    "cflags": "-O2",
    "c-include-dirs": [
        "vendor/dtoa",
        "libregexp"
    ],
    "targets": {
        "macos-aarch64": {},
        "macos-x64": {},
        "linux-x64": {
            "link-args": ["-lm", "-ldl"]
        },
        "linux-aarch64": {
            "link-args": ["-lm", "-ldl"]
        },
        "windows-x64": {}
    }
}
MANIFEST

echo "packed $C3L_DIR/ ($MODE mode)"
