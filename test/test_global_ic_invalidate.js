// Global-variable inline caches hold a slot pointer; growing the global
// bindings, deleting a binding or changing its attributes must not leave a
// loop reading a stale slot.
var g0 = 0, g1 = 1, g2 = 2;
var total = 0;
function assertEq(a, b, msg) { if (a !== b) throw new Error(msg + ": " + a + " !== " + b); }

// Storage growth: define many globals mid-loop so the property table moves.
for (var i = 0; i < 200; i++) {
    g0 += 1;
    g1 = g1 + 1;
    total += g2;
    if (i % 10 === 0) eval("var grown" + i + " = " + i);
}
assertEq(g0, 200, "g0");
assertEq(g1, 201, "g1");
assertEq(total, 400, "total");
assertEq(grown190, 190, "grown190");
assertEq(globalThis.g0, 200, "g0 via the global object");
assertEq(globalThis.g1, 201, "g1 via the global object");

// Deleting an eval-declared global and redeclaring it moves indices.
eval("var e1 = 1; var e2 = 2; var e3 = 3;");
var sum = 0;
for (var j = 0; j < 50; j++) {
    sum += e2 + e3;
    if (j === 25) { delete globalThis.e1; }
}
assertEq(sum, 250, "sum after delete");

// Attribute change: a global that turns read-only stops accepting stores.
eval("var ro = 0;");
for (var k = 0; k < 20; k++) {
    if (k === 10) Object.defineProperty(globalThis, "ro", { writable: false });
    ro = k + 100;
}
assertEq(ro, 109, "ro keeps last writable value");

// Accessor redefinition of a cached global.
eval("var acc = 1;");
var seen = 0;
for (var m = 0; m < 20; m++) {
    if (m === 10) Object.defineProperty(globalThis, "acc", { get: function () { return 7; }, configurable: true });
    seen += acc;
}
assertEq(seen, 10 * 1 + 10 * 7, "accessor");
