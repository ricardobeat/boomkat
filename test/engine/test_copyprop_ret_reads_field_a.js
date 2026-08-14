// Copy propagation must not treat a field-A *read* as a redefinition.
//
// The pass NOPs `LDREG rT = rS` when the next instruction consumes rT and rT is
// dead afterwards. Deadness came from a forward scan that stopped at the first
// instruction whose field A equalled rT, treating that as an overwrite. But A is
// a READ, not a write, for RET (and the IF_TRUE/IF_FALSE family, which the pass
// already special-cased). So a function whose only later mention of a variable
// was its own `return v` had that `v` declared dead, and the store was deleted.
//
// `for (o = i + (s = c); ...)` is the shape that exposes it: the embedded
// assignment `s = c` compiles to exactly that LDREG feeding the ADD, and `s`
// then survives only until the closing `return s`. The store vanished and `s`
// read back as undefined.
//
// This is how bignumber.js's multiply kernel hung forever. Its inner loop is
// `for (o = i + (s = c); o > i; ) ... b[--s] ...`; with the `s = c` store gone,
// `s` was undefined, `--s` produced NaN, every index read undefined, and the
// loop's termination arithmetic never converged. `.times()` never returned.
//
// Note the fix direction: an opcode not proven to write A must be treated as a
// possible READ (keeping the register live), never as a kill. Over-estimating
// liveness only forgoes an optimization; under-estimating it miscompiles.

var failures = 0;
function check(name, actual, expected) {
    if (actual !== expected) {
        print("FAIL: " + name + " -- expected " + expected + " got " + actual);
        failures++;
    }
}

// The minimal case: an embedded assignment in a for-init whose target's only
// later mention is the `return`. Before the fix this returned undefined.
function embeddedInitAssign() {
    var i = 1, c = 4, s, o;
    for (o = i + (s = c); o > i; ) { o--; }
    return s;
}
check("embeddedInitAssignSurvivesReturn", embeddedInitAssign(), 4);

// The same store, consumed by an array index inside the body. The `--s` here is
// what turned into NaN in bignumber.js. The loop carries its own iteration cap
// so a regression FAILS rather than hanging the suite.
function kernelShape() {
    var b = [1, 2, 3, 4, 5, 6], v = [0, 0, 0, 0, 0, 0, 0, 0];
    var i = 1, c = 4, s, o, guard = 0;
    for (o = i + (s = c); o > i; ) {
        if (++guard > 1000) { return "RUNAWAY"; }
        v[o--] = b[--s];
    }
    return v.join(",") + "|s=" + s + "|o=" + o;
}
check("multiplyKernelShape", kernelShape(), "0,0,1,2,3,4,0,0|s=0|o=1");

// Declaration order must not matter: `var o, s` happened to allocate registers
// that dodged the bug while `var s, o` hit it, which is why this looked like a
// heisenbug rather than a systematic miscompile.
function declOrderSwapped() {
    var v = [0, 0, 0, 0, 0, 0, 0, 0], i = 1, c = 4, o, s, guard = 0;
    for (o = i + (s = c); o > i; ) {
        if (++guard > 1000) { return "RUNAWAY"; }
        v[o--] = s;
    }
    return v.join(",") + "|s=" + s;
}
check("declOrderSwapped", declOrderSwapped(), "0,0,4,4,4,4,0,0|s=4");

// A returned value reached only through the copy-propagated consumer.
function returnedThroughConsumer() {
    var a = 3, b = 0;
    var t = a + (b = 7);
    return t + b;
}
check("returnedThroughConsumer", returnedThroughConsumer(), 17);

// The IF_TRUE/IF_FALSE case the pass already handled, kept as a guard so the
// allow-list rewrite cannot regress it.
function conditionalUse() {
    var c = 5, s;
    var o = 0 + (s = c);
    if (s) { return "live:" + s + ":" + o; }
    return "dead";
}
check("conditionalUse", conditionalUse(), "live:5:5");

if (failures === 0) {
    print("PASS: copy propagation preserves stores read only by RET");
} else {
    print("FAILED: " + failures + " check(s)");
}
