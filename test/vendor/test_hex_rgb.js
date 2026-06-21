import hexRgb from './hex-rgb.js';

var __pass = 0;
var __fail = 0;

function assert_eq(actual, expected, msg) {
  if (actual === expected) { __pass++; return; }
  __fail++;
  print("  FAIL: " + msg + " — expected «" + expected + "» got «" + actual + "»");
}

function assert_close(actual, expected, tol, msg) {
  var diff = actual > expected ? actual - expected : expected - actual;
  if (diff <= tol) { __pass++; return; }
  __fail++;
  print("  FAIL: " + msg);
}

// --- hex to RGB object ---
var r = hexRgb('#ff0000');
assert_eq(r.red, 255, 'red channel');
assert_eq(r.green, 0, 'green channel');
assert_eq(r.blue, 0, 'blue channel');
assert_eq(r.alpha, 1, 'alpha default');

r = hexRgb('#00ff00');
assert_eq(r.red, 0, 'r');
assert_eq(r.green, 255, 'g');
assert_eq(r.blue, 0, 'b');

r = hexRgb('#0000ff');
assert_eq(r.red, 0, 'b r');
assert_eq(r.green, 0, 'b g');
assert_eq(r.blue, 255, 'b b');

// --- shorthand hex ---
r = hexRgb('#fff');
assert_eq(r.red, 255, 'shorthand white');
assert_eq(r.green, 255, 'shorthand green');
assert_eq(r.blue, 255, 'shorthand blue');

r = hexRgb('#000');
assert_eq(r.red, 0, 'shorthand black');

// --- with alpha ---
r = hexRgb('#ff000080');
assert_eq(r.alpha, 0.5, 'alpha from 8-char hex');

// --- array format ---
var arr = hexRgb('#ff0000', {format: 'array'});
assert_eq(arr[0], 255, 'array red');
assert_eq(arr[1], 0, 'array green');
assert_eq(arr[3], 1, 'array alpha');

// --- css format ---
var css = hexRgb('#ff0000', {format: 'css'});
assert_eq(css, 'rgb(255 0 0)', 'css format');

// --- edge cases ---
r = hexRgb('#010203');
assert_eq(r.red, 1, 'small red');
assert_eq(r.green, 2, 'small green');
assert_eq(r.blue, 3, 'small blue');

print("hex-rgb: pass=" + __pass + " fail=" + __fail);
if (__fail > 0) { throw "HEX-RGB TEST FAILED"; }
