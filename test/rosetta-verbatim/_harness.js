// Shared assertion harness for the verbatim Rosetta suite.
//
// The samples under test are byte-identical copies of rosettacode.org code, so
// they carry no assertions of their own; each <name>.check.js states the
// expectations here. run.sh concatenates this file, the sample, and the check
// into one script, so these names are simply in scope -- there is no export.
var pass = 0, fail = 0;

function assert(cond, msg) {
    if (cond) { pass++; } else { fail++; print("FAIL: " + msg); }
}

function assertEq(actual, expected, msg) {
    assert(actual === expected, msg + " (expected " + expected + ", got " + actual + ")");
}

function report(name) {
    print("rosetta-verbatim/" + name + ": " + pass + " passed, " + fail + " failed");
    if (fail > 0) throw new Error("FAIL");
}
