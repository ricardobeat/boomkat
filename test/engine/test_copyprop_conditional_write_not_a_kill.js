// A write that sits past a conditional branch must not end a liveness scan.
//
// Copy propagation NOPs `LDREG rT = rS` when the next instruction consumes rT
// and rT is dead afterwards; the fusion passes fold `LDINT rK + SUB` the same
// way. Both computed deadness with a forward LINEAR scan over instruction
// slots, stopping at the first instruction whose field A equalled the register
// and calling that an overwrite. That scan is not a CFG walk: once it passes an
// IF_TRUE/IF_FALSE (or a JMP_* compare-branch) the instructions it sees only
// execute on the taken path, so a write there kills the register conditionally,
// not unconditionally. Treating it as a kill declares a still-live register
// dead and deletes the store that fed it.
//
// `(o = 1) - (r = 1) < 0 && (r = o)` is the minimal shape. `r`'s only mention
// after the subtraction is the `r = o` on the `&&`'s right-hand side, which is
// skipped whenever the comparison is false. The scan stopped there, so the
// LDREG carrying `r = 1` into the SUB was propagated away and never stored, and
// `r` read back as undefined on exactly the path that needed it.
//
// This is how decimal.js's plus() silently returned the wrong value. Its
// addition kernel opens with
// `for ((o = f.length) - (r = a.length) < 0 && (r = o, i = a, a = f, f = i), e = 0; r;)`
// -- with the `r = a.length` store gone, `r` was undefined, the loop test failed
// immediately, and the digit-array addition never ran. `plus()` returned a clone
// of its receiver, so `new Decimal("0.1").plus("0.2")` evaluated to "0.1".
//
// Fix direction, as with the RET-reads-A bug: past a conditional branch, only
// READS may be honoured, never kills. Over-estimating liveness forgoes a
// fusion; under-estimating it miscompiles.

var failures = 0;
function check(name, actual, expected) {
    if (actual !== expected) {
        print("FAIL: " + name + " -- expected " + expected + " got " + actual);
        failures++;
    }
}

// Minimal: the `&&` right-hand side is not taken, so `r` must keep its 1.
function notTaken() {
    var e, r, o;
    (o = 1) - (r = 1) < 0 && (r = o);
    return r;
}
check("notTaken", notTaken(), 1);

// Taken path still assigns, so the fix must not pin the old value either.
function taken() {
    var e, r, o;
    (o = 5) - (r = 1) > 0 && (r = o);
    return r;
}
check("taken", taken(), 5);

// The decimal.js kernel shape: a for-init whose condition variable is assigned
// inside the `&&`'s left operand and conditionally reassigned on its right.
function addDigits(d, n) {
    var e, i, r, o, f = d.slice(), a = n;
    for ((o = f.length) - (r = a.length) < 0 && (r = o, i = a, a = f, f = i), e = 0; r;) {
        f[--r] = f[r] + a[r];
    }
    return f.join(",");
}
check("addDigits equal length", addDigits([12], [34]), "46");
check("addDigits multi digit", addDigits([1, 2], [3, 4]), "4,6");

if (failures === 0) {
    print("PASS: a conditionally-executed write does not kill a live register");
} else {
    print("FAILED: " + failures + " check(s)");
}
