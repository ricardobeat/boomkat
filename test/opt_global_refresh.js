// An eval that declares globals retires every global variable cache (Heap.invalidate_var_ic_entries).
// Optimized reads and stores of a global refresh their entry and keep their results, and a global
// a later declaration shadows is read from its new binding.
var counter = 0;
var step = 1;
var box = { zero: 0, one: 1 };
function run(n) {
    var s = 0;
    for (var i = 0; i < n; i++) {
        counter += step * box.one;
        s += counter + box.zero;
    }
    return s;
}
function expect(n, from, by) { return n * from + by * n * (n + 1) / 2; }

for (var w = 0; w < 50; w++) {
    var base = counter;
    if (run(1000) !== expect(1000, base, 1)) throw new Error("warm-up");
}
for (var k = 0; k < 40; k++) {
    (0, eval)("var declared" + k + " = " + k);
    step = (k & 1) + 1;
    base = counter;
    if (run(500) !== expect(500, base, step)) throw new Error("after eval " + k);
}
if (declared39 !== 39) throw new Error("declared39");

// A configurable global replaced through the global object reads the new value.
globalThis.shared = 5;
function readShared() { return shared; }
function sumShared(n) { var s = 0; for (var i = 0; i < n; i++) s += readShared(); return s; }
if (sumShared(20000) !== 100000) throw new Error("shared");
(0, eval)("var another = 1");
delete globalThis.shared;
globalThis.shared = 7;
if (sumShared(100) !== 700) throw new Error("shared after delete");
console.log("ok");
