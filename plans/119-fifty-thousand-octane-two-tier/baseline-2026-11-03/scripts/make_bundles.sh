#!/bin/zsh
# Build the single-file Octane bundles used by the other scripts.
#
# usage: make_bundles.sh <octane-source-dir> <out-dir>
#
# <out-dir> receives octane-all.js (suite order), octane-navier-first.js
# (NavierStokes moved to the front) and single/<name>.js, one bundle per
# benchmark with base.js and the original run.js driver. The `read` stub
# satisfies the shell detection in zlib; no benchmark calls it.
set -e
O=${1:?octane source dir}
OUT=${2:?out dir}
mkdir -p $OUT/single
SHIM='if (typeof read === "undefined") { globalThis.read = function (f) { throw new Error("read " + f); }; }'
driver() { sed -n '/^var success = true;/,$p' $O/run.js; }
suite() { echo $SHIM; for f in base.js "$@"; do cat $O/$f; echo; done; driver; }
ALL=(richards.js deltablue.js crypto.js raytrace.js earley-boyer.js regexp.js splay.js
     navier-stokes.js pdfjs.js mandreel.js gbemu-part1.js gbemu-part2.js code-load.js
     box2d.js zlib.js zlib-data.js typescript.js typescript-input.js typescript-compiler.js)
suite $ALL > $OUT/octane-all.js
suite navier-stokes.js ${ALL:#navier-stokes.js} > $OUT/octane-navier-first.js
# Per-benchmark bundles have no blank line after base.js.
one() {
    local name=$1; shift
    { echo $SHIM; cat $O/base.js; for f in "$@"; do cat $O/$f; echo; done; driver; } > $OUT/single/$name.js
}
one richards richards.js; one deltablue deltablue.js; one crypto crypto.js
one raytrace raytrace.js; one earley earley-boyer.js; one regexp regexp.js
one splay splay.js; one navier navier-stokes.js; one pdfjs pdfjs.js
one mandreel mandreel.js; one gbemu gbemu-part1.js gbemu-part2.js
one codeload code-load.js; one box2d box2d.js; one zlib zlib.js zlib-data.js
one typescript typescript.js typescript-input.js typescript-compiler.js
