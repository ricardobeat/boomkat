import parseMs from './parse-ms.js';

var __pass = 0;
var __fail = 0;

function assert_eq(actual, expected, msg) {
  if (actual === expected) { __pass++; return; }
  __fail++;
  print("  FAIL: " + msg + " — expected «" + expected + "» got «" + actual + "»");
}

var r = parseMs(1000);
assert_eq(r.days, 0, '1s days');
assert_eq(r.hours, 0, '1s hours');
assert_eq(r.minutes, 0, '1s minutes');
assert_eq(r.seconds, 1, '1s seconds');
assert_eq(r.milliseconds, 0, '1s ms');

r = parseMs(60000);
assert_eq(r.minutes, 1, '1m minutes');

r = parseMs(3600000);
assert_eq(r.hours, 1, '1h hours');

r = parseMs(86400000);
assert_eq(r.days, 1, '1d days');

r = parseMs(1001);
assert_eq(r.seconds, 1, '1001ms seconds');
assert_eq(r.milliseconds, 1, '1001ms ms');

r = parseMs(0);
assert_eq(r.days, 0, '0ms');
assert_eq(r.milliseconds, 0, '0ms ms');

r = parseMs(123456789);
assert_eq(r.days, 1, 'large days');
assert_eq(r.hours, 10, 'large hours');
assert_eq(r.minutes, 17, 'large minutes');
assert_eq(r.seconds, 36, 'large seconds');
assert_eq(r.milliseconds, 789, 'large ms');

print("parse-ms: pass=" + __pass + " fail=" + __fail);
if (__fail > 0) { throw "PARSE-MS TEST FAILED"; }
