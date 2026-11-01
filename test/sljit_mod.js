// Remainder in compiled bodies.
//
// The fastint quotient with its -0 and zero-divisor results written inline,
// slow operands that resume in the interpreter, and the loop-carried hashing
// and wrapping patterns hot code uses `%` for. Every checksum has an
// interpreted reference so the differential run compares both tiers.

var ok = 0;
function check(name, got, want) {
  if (!Object.is(got, want)) throw new Error(name + " got " + got + " want " + want);
  ok++;
}

// One operand pair per call so the quotient, its sign rules and every slow
// operand shape run through the same compiled body.
function sem(x, y, n) {
  var last = 0;
  for (var i = 0; i < n; i++) last = x % y;
  return last;
}
check("pos", sem(7, 3, 20000), 1);
check("negdiv", sem(-5, 3, 20000), -2);
check("negmod", sem(5, -3, 20000), 2);
check("negneg", sem(-5, -3, 20000), -2);
check("exact", sem(6, 3, 20000), 0);
check("negzero", sem(-6, 3, 20000), -0);
check("negone", sem(5, -1, 20000), 0);
check("negone-neg", sem(-5, -1, 20000), -0);
check("zerodiv", sem(5, 0, 20000), NaN);
check("zerodiv-neg", sem(-5, 0, 20000), NaN);
check("zero-zero", sem(0, 0, 20000), NaN);
check("float", sem(5.5, 2, 20000), 1.5);
check("floatneg", sem(-5.5, 2, 20000), -1.5);
check("mixed", sem(5, 2.5, 20000), 0);
check("mixedneg", sem(-5, 2.5, 20000), -0);
check("big", sem(9007199254740991, 1000, 20000), 991);
check("bigneg", sem(-9007199254740991, 1000, 20000), -991);
check("huge", sem(1e21, 7, 20000), 6);
check("str", sem("10", 3, 20000), 1);
check("null", sem(null, 3, 20000), 0);
check("undef", sem(undefined, 3, 20000), NaN);
check("bool", sem(true, 2, 20000), 1);

// A small compiled callee keeps the quotient on the call path.
function tick(x, y) { return x % y; }
var spin = 0;
for (var k = 0; k < 30000; k++) spin += tick(1000 + (k & 127), 101);
check("tick", spin, 1438652);

// Wrapping accumulators, the shape of checksum and hash code.
function wrap(n) {
  var s = 0, t = 0;
  for (var i = 0; i < n; i++) { s = (s + i * 7) % 1000; t += s; }
  return t + s;
}
check("wrap", wrap(40000), 19820000);

function hash(n) {
  var h = 0, t = 0;
  for (var i = 0; i < n; i++) { h = (h * 31 + i) % 65521; t += h; }
  return t + h;
}
check("hash", hash(20000), 649981350);

// Negative dividends: zero remainders are -0 and mixed signs stay truncated.
function signed(n) {
  var s = 0, t = 0;
  for (var i = 0; i < n; i++) { s += (i - (n >> 1)) % 7; t += s; }
  return t + s;
}
check("signed", signed(40000), -1200019999);

// Double operands on the slow path, summed in canonical numeric lanes.
function doubles(n) {
  var s = 0;
  for (var i = 0; i < n; i++) s += (i * 0.5 + 0.25) % 3;
  return s + 0.125;
}
check("doubles", doubles(40000), 59998.125);

// A typed-array accumulator, the shape of image and emulator code.
var data = new Uint8Array(64);
for (var i = 0; i < 64; i++) data[i] = (i * 13) & 0xFF;
function pixels(n) {
  var s = 0, t = 0;
  for (var k = 0; k < n; k++) {
    for (var i = 0; i < 64; i++) { s = (s + data[i]) % 997; t += s; }
  }
  return t + s;
}
check("pixels", pixels(2000), 63746886);

print("sljit mod ok", ok);
