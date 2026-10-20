// Closures capturing an enclosing local. The capture-analysis path: a captured
// binding is demoted from a register into an environment record, so every read
// and write goes through the env instead of a register.
//
// Exactly one benchmark in the ES5 suite uses a closure at all, which is why
// work on this path was invisible there.
var N = 3000000;

// A closure exists over `s` but the loop itself never calls it. The binding is
// still captured, so the loop pays env access on every step.
function capturedNotCalled(n) {
    let s = 0, i = 0;
    const peek = () => s;
    while (i < n) { s = s + i; i = i + 1; }
    return s;
}

// The closure is called each iteration, so the env read is on the hot path.
function capturedAndCalled(n) {
    let s = 0, i = 0;
    const peek = () => s;
    while (i < n) { s = peek() + i; i = i + 1; }
    return s;
}

// Nothing captures anything: the floor these should be measured against.
function uncaptured(n) {
    let s = 0, i = 0;
    while (i < n) { s = s + i; i = i + 1; }
    return s;
}

var r = 0;
r += capturedNotCalled(N);
r += capturedAndCalled(N / 3);
r += uncaptured(N);
if (r === 0) throw new Error("optimized away");
