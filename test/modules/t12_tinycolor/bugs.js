// Minimal repro for C3 ESM module compiler bug.
// Two issues triggered by tinycolor.esm.js:
//
// BUG 1: Function declaration hoisting corruption.
//   After many function declarations, a `var x = IIFE()` assignment
//   is not visible to functions defined later in the same module.
//   In tinycolor: `var matchers = function(){...}()` (line ~990) is
//   `undef` when accessed from `stringInputToObject()` (line ~1060),
//   despite being defined earlier. This makes all regex parsing fail.
//
// BUG 2: Babel's `_typeof` self-reassignment pattern corrupts the
//   next function declaration binding:
//     function _typeof(obj) { return _typeof = ..., _typeof(obj); }
//     function stringInputToObject(...)  // .name == "_typeof"
//
// Manifestation: either wrong values (ok:false, _format:[object Object])
// or SIGSEGV (exit 139) depending on memory layout.
//
// Repro: ./out/boomkat --module test/modules/t12_tinycolor/bugs.js
// Expected: "ok: true, r: 255"  Actual: crash or wrong values

import tinycolor from '../../vendor/tinycolor.esm.js';

var c = tinycolor("red");
console.log("ok:", c._ok, "expected: true");
console.log("r:", c._r, "expected: 255");
console.log("format:", c._format, "expected: name");

if (c.isValid() && c._r === 255) {
  console.log("PASS");
} else {
  console.log("FAIL — C3 ESM compiler bug");
}
