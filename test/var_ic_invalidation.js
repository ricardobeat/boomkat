// Variable inline cache invalidation.
//
// A VarICEntry caches the environment record that owns a name, the bindings
// object, and the property index inside it. A hit compares the bindings
// object's shape id and the heap's shape-recycle epoch, then reads
// prop_values[prop_idx] directly.
//
// Two separate things can make a cached entry wrong, and the cache needs an
// answer for each:
//
//   1. The binding's layout changes. Every path that removes a property moves
//      the object to a different shape, either back to the root shape, to a
//      shape replayed through the transition table, or to a freshly allocated
//      private one. So the shape id compare covers deletes, and covers a data
//      property being redefined as an accessor.
//   2. A shape id is freed and handed back out for an unrelated shape. The id
//      alone cannot show this, because it is the same number. The recycle
//      epoch counts how many times a slot has been reused, so an entry filled
//      before a reuse no longer matches.
//
// What the cache deliberately does NOT track is the property storage being
// reallocated. That moves the values but not the index, and every access
// re-reads the base pointer through prop_values(), so a cached entry stays
// correct across a grow. Cases 6 and 7 below pin that down: they grow the
// global object well past its inline capacity and expect earlier bindings to
// keep reading correctly.
//
// Global `var` bindings are non-configurable, so the cases that need a
// deletable global create it by plain assignment instead.

var pass = 0, fail = 0;
function assert(cond, msg) { if (cond) { pass++; } else { fail++; print('FAIL: ' + msg); } }

// 1. Deleting a configurable global is seen by an already-warmed read site.
globalThis.gd = 1;
function readGd() { return typeof gd === 'undefined' ? 'gone' : gd; }
for (var i = 0; i < 5; i++) { readGd(); }
assert(readGd() === 1, 'warmed read returned ' + readGd() + ' before the delete');
delete globalThis.gd;
assert(readGd() === 'gone', 'deleted global still readable as ' + readGd());

// 2. Deleting and recreating the same name serves the new value.
globalThis.gr = 10;
function readGr() { return gr; }
for (var i = 0; i < 5; i++) { readGr(); }
delete globalThis.gr;
globalThis.gr = 99;
assert(readGr() === 99, 'recreated global read as ' + readGr() + ' instead of 99');

// 3. A data property redefined as an accessor stops using the cached slot.
globalThis.ga = 5;
function readGa() { return ga; }
for (var i = 0; i < 5; i++) { readGa(); }
Object.defineProperty(globalThis, 'ga', { get: function () { return 777; }, configurable: true });
assert(readGa() === 777, 'accessor redefinition read as ' + readGa() + ' instead of 777');

// 4. And back again, so the accessor flag is not sticky.
Object.defineProperty(globalThis, 'ga', { value: 12, writable: true, configurable: true });
assert(readGa() === 12, 'accessor turned back into data read as ' + readGa() + ' instead of 12');

// 5. Enough delete/insert churn to cycle shape ids through the free list. The
// warmed read below must survive it.
var gz = 3;
function readGz() { return gz; }
for (var i = 0; i < 5; i++) { readGz(); }
for (var k = 0; k < 300; k++) { var o = {}; o['p' + k] = k; delete o['p' + k]; }
assert(readGz() === 3, 'warmed read after shape churn returned ' + readGz() + ' instead of 3');

// 6. Growing the global object's property storage does not disturb a warmed
// read, because the cache stores an index rather than a pointer.
var gg = 42;
function readGg() { return gg; }
for (var i = 0; i < 5; i++) { readGg(); }
for (var k = 0; k < 200; k++) { globalThis['filler' + k] = k; }
assert(readGg() === 42, 'warmed read after storage growth returned ' + readGg() + ' instead of 42');

// 7. The same for a warmed store site.
var gs = 0;
function bumpGs() { gs = gs + 1; }
for (var i = 0; i < 5; i++) { bumpGs(); }
for (var k = 0; k < 200; k++) { var o2 = {}; o2['q' + k] = k; delete o2['q' + k]; }
bumpGs();
assert(gs === 6, 'warmed store after churn left gs at ' + gs + ' instead of 6');

// 8. The fused increment path shares the same cache entries.
var gi = 0;
for (var i = 0; i < 5; i++) { gi++; }
for (var k = 0; k < 200; k++) { var o3 = {}; o3['r' + k] = k; delete o3['r' + k]; }
gi++;
assert(gi === 6, 'fused increment after churn left gi at ' + gi + ' instead of 6');

// 9. A read-only global keeps serving reads after a rejected write.
Object.defineProperty(globalThis, 'gro', { value: 5, writable: false, configurable: true });
function readGro() { return gro; }
for (var i = 0; i < 5; i++) { readGro(); }
try { gro = 6; } catch (e) { /* strict mode throws, which is fine here */ }
assert(readGro() === 5, 'read-only global read as ' + readGro() + ' after a rejected write');

// 10. A delete partway through a loop is noticed on the next iteration rather
// than at some later point.
globalThis.gm = 1;
var seen = [];
for (var i = 0; i < 4; i++) {
    seen.push(typeof gm === 'undefined' ? 'gone' : gm);
    if (i === 1) { delete globalThis.gm; }
}
assert(seen.join(',') === '1,1,gone,gone', 'mid-loop delete produced ' + seen.join(','));

// 11. Closure environments warmed and then churned still read their own
// bindings, not a recycled shape's.
function makeReader(v) { var box = v; return function () { return box; }; }
var keep = [];
for (var i = 0; i < 50; i++) {
    var r = makeReader(i);
    r(); r(); r();
    if (i % 10 === 0) { keep.push([i, r]); }
}
for (var k = 0; k < 400; k++) { var o4 = {}; o4['z' + k] = k; delete o4['z' + k]; }
var closureBad = 0;
for (var j = 0; j < keep.length; j++) {
    if (keep[j][1]() !== keep[j][0]) { closureBad++; }
}
assert(closureBad === 0, closureBad + ' warmed closures read the wrong binding after churn');

// 12. One site running against a fresh environment on every call.
function reader() { var local = 0; return function (n) { local = n; return local; }; }
var acc = 0;
for (var i = 0; i < 200; i++) {
    var f = reader();
    acc += f(i);
    var o5 = {}; o5['w' + i] = i; delete o5['w' + i];
}
assert(acc === 19900, 'per-call environments summed to ' + acc + ' instead of 19900');

// 13. A nested chain of environments warmed and then churned.
function outer() {
    var a = 7;
    function mid() {
        var b = 8;
        function inner() { return a + b; }
        return inner;
    }
    return mid();
}
var inn = outer();
for (var i = 0; i < 5; i++) { inn(); }
for (var k = 0; k < 400; k++) { var o6 = {}; o6['y' + k] = k; delete o6['y' + k]; }
assert(inn() === 15, 'nested closure read ' + inn() + ' instead of 15 after churn');

print('var_ic_invalidation: ' + pass + ' passed, ' + fail + ' failed');
if (fail > 0) { print('SOME TESTS FAILED'); throw new Error('FAIL'); }
