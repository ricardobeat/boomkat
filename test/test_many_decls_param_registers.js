// Function parameters must survive a scope with many hoisted declarations.
//
// Instruction operands are 8 bits (MAX_A/B/C = 0xFF in src/bytecode.c3), but
// MAX_REGISTERS was 65535, so the reg_overflow -> COMPILE_ERROR guard in
// src/compiler/regalloc.c3 could never fire. Past 256 registers the index was
// masked to & 0xFF: the allocator saturated at r255, the call argument was
// written to the wrong register, and the parameter read back as undefined —
// silently, with no compile error and no exception.
//
// Hoisted function declarations are what consume a register each; they sit
// below reserved_regs and are never released. `var f = function(){}` and
// object-literal methods free theirs, so only declarations trigger this.
//
// The callee must do work of its own (call out, or write to an outer
// binding). A callee that only returns its parameter keeps the value in a
// register that happens to survive, and does not expose the bug.
//
// Found via underscore.js, whose UMD factory has 109 top-level declarations
// plus vars and temporaries. See plans/070-real-world-battle-testing.md.
var failures = 0;
function assertEq(actual, expected, msg) {
    if (actual !== expected) {
        print("FAIL: " + msg + " — expected " + expected + ", got " + actual);
        failures++;
    }
}

(function () {
    function f0() { return 0; }
    function f1() { return 1; }
    function f2() { return 2; }
    function f3() { return 3; }
    function f4() { return 4; }
    function f5() { return 5; }
    function f6() { return 6; }
    function f7() { return 7; }
    function f8() { return 8; }
    function f9() { return 9; }
    function f10() { return 10; }
    function f11() { return 11; }
    function f12() { return 12; }
    function f13() { return 13; }
    function f14() { return 14; }
    function f15() { return 15; }
    function f16() { return 16; }
    function f17() { return 17; }
    function f18() { return 18; }
    function f19() { return 19; }
    function f20() { return 20; }
    function f21() { return 21; }
    function f22() { return 22; }
    function f23() { return 23; }
    function f24() { return 24; }
    function f25() { return 25; }
    function f26() { return 26; }
    function f27() { return 27; }
    function f28() { return 28; }
    function f29() { return 29; }
    function f30() { return 30; }
    function f31() { return 31; }
    function f32() { return 32; }
    function f33() { return 33; }
    function f34() { return 34; }
    function f35() { return 35; }
    function f36() { return 36; }
    function f37() { return 37; }
    function f38() { return 38; }
    function f39() { return 39; }
    function f40() { return 40; }
    function f41() { return 41; }
    function f42() { return 42; }
    function f43() { return 43; }
    function f44() { return 44; }
    function f45() { return 45; }
    function f46() { return 46; }
    function f47() { return 47; }
    function f48() { return 48; }
    function f49() { return 49; }
    function f50() { return 50; }
    function f51() { return 51; }
    function f52() { return 52; }
    function f53() { return 53; }
    function f54() { return 54; }
    function f55() { return 55; }
    function f56() { return 56; }
    function f57() { return 57; }
    function f58() { return 58; }
    function f59() { return 59; }
    function f60() { return 60; }
    function f61() { return 61; }
    function f62() { return 62; }
    function f63() { return 63; }
    function f64() { return 64; }
    function f65() { return 65; }
    function f66() { return 66; }
    function f67() { return 67; }
    function f68() { return 68; }
    function f69() { return 69; }
    function f70() { return 70; }
    function f71() { return 71; }
    function f72() { return 72; }
    function f73() { return 73; }
    function f74() { return 74; }
    function f75() { return 75; }
    function f76() { return 76; }
    function f77() { return 77; }
    function f78() { return 78; }
    function f79() { return 79; }
    function f80() { return 80; }
    function f81() { return 81; }
    function f82() { return 82; }
    function f83() { return 83; }
    function f84() { return 84; }
    function f85() { return 85; }
    function f86() { return 86; }
    function f87() { return 87; }
    function f88() { return 88; }
    function f89() { return 89; }
    function f90() { return 90; }
    function f91() { return 91; }
    function f92() { return 92; }
    function f93() { return 93; }
    function f94() { return 94; }
    function f95() { return 95; }
    function f96() { return 96; }
    function f97() { return 97; }
    function f98() { return 98; }
    function f99() { return 99; }
    function f100() { return 100; }
    function f101() { return 101; }
    function f102() { return 102; }
    function f103() { return 103; }
    function f104() { return 104; }
    function f105() { return 105; }
    function f106() { return 106; }
    function f107() { return 107; }
    function f108() { return 108; }
    function f109() { return 109; }
    function f110() { return 110; }
    function f111() { return 111; }
    function f112() { return 112; }
    function f113() { return 113; }
    function f114() { return 114; }
    function f115() { return 115; }
    function f116() { return 116; }
    function f117() { return 117; }
    function f118() { return 118; }
    function f119() { return 119; }
    function f120() { return 120; }
    function f121() { return 121; }
    function f122() { return 122; }
    function f123() { return 123; }
    function f124() { return 124; }
    function f125() { return 125; }
    function f126() { return 126; }
    function f127() { return 127; }
    function f128() { return 128; }
    function f129() { return 129; }

    // The callee writes to an outer binding, so the argument must be live in
    // the right register across real work.
    var seenType, seenValue;
    function observe(p) {
        seenType = typeof p;
        seenValue = p;
    }

    observe(123);
    assertEq(seenType, "number", "number parameter survives 130 sibling declarations");
    assertEq(seenValue, 123, "number parameter keeps its value");

    observe("hello");
    assertEq(seenType, "string", "string parameter survives");
    assertEq(seenValue, "hello", "string parameter keeps its value");

    // Several parameters at once: each must land in its own register.
    var joined;
    function observeThree(a, b, c) { joined = a + "," + b + "," + c; }
    observeThree(1, 2, 3);
    assertEq(joined, "1,2,3", "three parameters all survive");

    // The shape underscore's restArguments used: read .length off a function
    // argument, inside a callee that then does further work.
    var seenArity;
    function recordArity(fn) { seenArity = fn.length; }
    recordArity(function (a, b) { return a + b; });
    assertEq(seenArity, 2, "function-valued argument reaches the callee intact");

    // The declarations themselves must remain callable and distinct.
    assertEq(f0() + f129(), 129, "hoisted declarations still callable");
    assertEq(f64(), 64, "a declaration past the 8-bit boundary is intact");
}());

if (failures === 0) {
    print("PASS: parameters survive a register-heavy scope");
} else {
    print("FAILURES: " + failures);
}
