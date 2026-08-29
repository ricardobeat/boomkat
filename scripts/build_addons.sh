#!/bin/bash
# Build every native add-on under addons/ into a loadable shared library.
#
# An add-on links against no engine symbol — it only needs include/boomkat_addon.h,
# which declares the BkAddonApi vtable it receives at load time. Verify that with:
#     nm -u addons/deflate/deflate.dylib
set -euo pipefail

PROJ_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CC="${CC:-cc}"

case "$(uname -s)" in
    Darwin) EXT=dylib ;;
    *)      EXT=so ;;
esac

built=0
for dir in "$PROJ_DIR"/addons/*/; do
    name=$(basename "$dir")
    srcs=("$dir"*.c)
    [ -e "${srcs[0]}" ] || continue

    # Per-add-on link flags, e.g. deflate needs zlib.
    libs=""
    [ -f "$dir/LIBS" ] && libs=$(cat "$dir/LIBS")

    out="$dir$name.$EXT"
    echo "  building $name -> ${out#$PROJ_DIR/}"
    # shellcheck disable=SC2086
    "$CC" -shared -fPIC -O2 -I"$PROJ_DIR/include" -o "$out" "${srcs[@]}" $libs
    built=$((built + 1))
done

echo "Built $built add-on(s)."
