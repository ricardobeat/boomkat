// Ackermann function
// Classic deeply-recursive function. Tests call stack depth.

function ack(m, n) {
    if (m === 0) return n + 1;
    if (n === 0) return ack(m - 1, 1);
    return ack(m - 1, ack(m, n - 1));
}

var pass = 0, fail = 0;
function assert(cond, msg) { if (cond) pass++; else { fail++; print("FAIL: " + msg); } }

assert(ack(0, 0) === 1, "ack(0,0)=1");
assert(ack(0, 5) === 6, "ack(0,5)=6");
assert(ack(1, 0) === 2, "ack(1,0)=2");
assert(ack(1, 1) === 3, "ack(1,1)=3");
assert(ack(2, 1) === 5, "ack(2,1)=5, got " + ack(2, 1));
// ack(3,n) grows as 2^(n+3)-3 and recurses that deep; capped at ack(3,5)
// to keep the test fast, not to work around a stack limit.
assert(ack(2, 5) === 13, "ack(2,5)=13, got " + ack(2, 5));
assert(ack(3, 3) === 61, "ack(3,3)=61, got " + ack(3, 3));
assert(ack(3, 5) === 253, "ack(3,5)=253, got " + ack(3, 5));
assert(ack(3, 0) === 5, "ack(3,0)=5, got " + ack(3, 0));

print("engine/ackermann: " + pass + " passed, " + fail + " failed");
if (fail > 0) throw new Error("FAIL");
