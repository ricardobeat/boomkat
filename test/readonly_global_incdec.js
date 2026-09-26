// ++/-- on a global another script made read-only: sloppy code leaves it
// unchanged, strict code throws a TypeError (ES2024 PutValue step 5).
var fail = 0;
function check(name, got, want) {
    if (got !== want) { print("FAIL " + name + ": got " + got + " want " + want); fail++; }
}

check("sloppy postfix at top level",
    $262.evalScript("var k1 = 1; $262.evalScript('Object.defineProperty(globalThis, \"k1\", {writable: false})'); k1++; k1"), 1);
check("sloppy prefix in a function",
    $262.evalScript("var m1 = 1; $262.evalScript('Object.defineProperty(globalThis, \"m1\", {writable: false})'); function bump() { return --m1; } bump(); m1"), 1);
var threw = "none";
try {
    $262.evalScript("'use strict'; var s1 = 1; $262.evalScript('Object.defineProperty(globalThis, \"s1\", {writable: false})'); s1++;");
} catch (e) { threw = e.constructor.name; }
check("strict throws", threw, "TypeError");

print(fail === 0 ? "readonly_global_incdec: all passed"
                 : "readonly_global_incdec: " + fail + " FAILED");
