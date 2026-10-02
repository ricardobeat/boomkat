// A method call on a BigInt intermediate, `obj.ns.toString()` with `obj.ns`
// returning 5n from an accessor getter, must resolve `toString` through
// BigInt.prototype like every other boxed intermediate.
//
// The call matters: reading the value alone (`a.b.toString` as a property)
// takes the single-hop path.
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
  eq(i.epochMilliseconds.toString(), "1000", "Instant.epochMilliseconds.toString");
})();

// --- bigint returned from a plain (non-accessor) call still chains ---
(function () {
  var b = BigInt(7);
  eq(b.toString(), "7", "BigInt from a call chains");
})();

print("Pass: " + pass + " Fail: " + fail);
if (fail > 0) process.exit(1);