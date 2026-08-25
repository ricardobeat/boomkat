// Regression pair for the GETPROPC2 fused two-hop chain: the second hop's
// primitive handling covered string/number/boolean/null but had no BigInt
// case, so a BigInt almost certainly returned by an accessor getter (e.g.
// `obj.ns` -> 5n) fell through to the bare `ra2.set_undefined()` else-branch
// when a method was called on it. `obj.ns.toString()` therefore resolved
// `toString` to undefined. Every other boxed intermediate worked; only BigInt
// was dropped.
//
// The trigger needs a *method call* on hop 2 (`a.b.toString()`) so the pair
// fuses into GETPROPC2; reading the value alone (`a.b.toString` as a property)
// uses a single GETPROPC and never hits the missing branch.

var pass = 0, fail = 0;

function assert(cond, msg) {
  if (cond) { pass++; }
  else { fail++; print("FAIL: " + msg); }
}

function eq(actual, expected, msg) {
  assert(actual === expected, msg + " (got " + String(actual) + ", want " + String(expected) + ")");
}

// --- BigInt accessor, method call on the second hop ---
(function () {
  var o = { get ns() { return 5n; } };
  eq(o.ns.toString(), "5", "bigint accessor chained with toString");
  eq(o.ns.valueOf(), 5n, "bigint accessor chained with valueOf");
})();

// --- a real Temporal.Instant.epochNanoseconds.accessor chain ---
(function () {
  var i = new Temporal.Instant(1000000000n);
  eq(i.epochNanoseconds.toString(), "1000000000", "Instant.epochNanoseconds.toString");
  eq(i.epochSeconds.toString(), "1", "Instant.epochSeconds.toString");
})();

// --- bigint returned from a plain (non-accessor) call still chains ---
(function () {
  var b = BigInt(7);
  eq(b.toString(), "7", "BigInt from a call chains");
})();

print("Pass: " + pass + " Fail: " + fail);
if (fail > 0) process.exit(1);