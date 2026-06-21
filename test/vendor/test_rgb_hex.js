import rgbHex from './rgb-hex.js';

var __pass = 0;
var __fail = 0;

function assert_eq(actual, expected, msg) {
  if (actual === expected) { __pass++; return; }
  __fail++;
  print("  FAIL: " + msg + " — expected «" + expected + "» got «" + actual + "»");
}

assert_eq(rgbHex(255, 255, 255), 'ffffff', 'white');
assert_eq(rgbHex(0, 0, 0), '000000', 'black');
assert_eq(rgbHex(255, 0, 0), 'ff0000', 'red');
assert_eq(rgbHex(0, 255, 0), '00ff00', 'green');
assert_eq(rgbHex(0, 0, 255), '0000ff', 'blue');
assert_eq(rgbHex(65, 105, 225), '4169e1', 'royalblue');
assert_eq(rgbHex(1, 2, 3), '010203', 'small values');
assert_eq(rgbHex(255, 255, 255, 0.5), 'ffffff80', 'with alpha fraction');
assert_eq(rgbHex(255, 255, 255, 1), 'ffffff01', 'with alpha 1');
assert_eq(rgbHex(255, 255, 255, 0), 'ffffff00', 'with alpha 0');

// --- CSSting input ---
assert_eq(rgbHex('rgb(255,0,0)'), 'ff0000', 'css string red');
assert_eq(rgbHex('rgb(0, 255, 0)'), '00ff00', 'css string green');

// --- edge: min/max ---
assert_eq(rgbHex(0, 0, 0), '000000', 'min values');
assert_eq(rgbHex(255, 255, 255), 'ffffff', 'max values');

print("rgb-hex: pass=" + __pass + " fail=" + __fail);
if (__fail > 0) { throw "RGB-HEX TEST FAILED"; }
