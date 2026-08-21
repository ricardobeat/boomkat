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
link_or_copy "quickjs"

# The public API binding: lives at bindings/c3/boomkat.c3, placed at the .c3l root
# so it is compiled as `module boomkat` (its own declaration).
if [[ "$MODE" == "copy" ]]; then
    cp "bindings/c3/boomkat.c3" "$C3L_DIR/boomkat.c3"
else
    ln -s "../../bindings/c3/boomkat.c3" "$C3L_DIR/boomkat.c3"
fi

# --- manifest.json -------------------------------------------------------------
cat > "$C3L_DIR/manifest.json" <<'MANIFEST'
{
    "provides": "boomkat",
    "sources": [
        "src",
        "boomkat.c3"
    ],
    "c-sources": [
        "libregexp/libregexp.c",
        "libregexp/libunicode.c",
        "libregexp/re_wrapper.c",
        "libregexp/unicode_wrapper.c",
        "quickjs/cutils.c",
        "quickjs/dtoa.c",
        "src/dtoa_wrapper.c",
        "src/date_math.c"
    ],
    "cflags": "-O2",
    "c-include-dirs": [
        "quickjs",
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
