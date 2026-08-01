// Deleting a property gives the object a private shape describing the surviving
// layout. The shape free list reclaims those, so a delete/insert loop reuses
// slots instead of exhausting the pool.
//
// An earlier version instead replayed every surviving key through the
// transition table on each delete, so that same-layout objects would converge on
// one shared shape. That cost O(N) transitions per delete, making a teardown
// O(N^2): 4000 deletes took 270ms against 25ms without it. Measured across
// object-allocation throughput, teardown, and post-delete property reads, the
// sharing bought nothing outside the noise floor, so it is gone.
//
// This guards the cost. Absolute time is the signal, not a ratio: both the fast
// and slow forms grow superlinearly, so their ratios overlap and cannot separate
// them. The bound below is ~5x the measured time, well clear of machine noise
// but far under the regressed figure.
function teardown(n) {
    var o = {};
    for (var i = 0; i < n; i++) o["p" + i] = i;
    var t0 = Date.now();
    for (var i = n - 1; i >= 0; i--) delete o["p" + i];
    return { ms: Date.now() - t0, left: Object.keys(o).length };
}

var small = teardown(1000);
if (small.left !== 0) throw new Error("delete left " + small.left + " properties behind");

// Measured ~2.4ms here, ~14ms when every delete replayed the surviving keys.
if (small.ms > 12) {
    throw new Error("deleting 1000 properties took " + small.ms.toFixed(1) +
                    "ms; expected well under 12ms (shape rebuild is O(N) per delete again?)");
}

var large = teardown(4000);
if (large.left !== 0) throw new Error("delete left " + large.left + " properties behind");

// Measured ~25ms here, ~270ms with the per-delete replay.
if (large.ms > 120) {
    throw new Error("deleting 4000 properties took " + large.ms.toFixed(1) +
                    "ms; expected well under 120ms (shape rebuild is O(N) per delete again?)");
}

// The shape pool must still be reclaimed. This is the corruption the free list
// fixes: without it, each iteration burns slots until every newly allocated
// object silently loses its properties.
var o = { a: 1, b: 2 };
for (var j = 0; j < 200000; j++) { o.c = j; delete o.c; }
if (o.a !== 1 || Object.keys({ x: 7, y: 8 }).length !== 2) {
    throw new Error("shape pool exhausted by delete/insert loop");
}

// Same, on a wide object, where the private shape is larger.
var wide = {};
for (var i = 0; i < 100; i++) wide["w" + i] = i;
for (var j = 0; j < 200000; j++) { wide.tmp = j; delete wide.tmp; }
if (wide.w0 !== 0 || wide.w99 !== 99 || Object.keys({ m: 1, n: 2 }).length !== 2) {
    throw new Error("shape pool exhausted by churn on a wide object");
}

// Deleting from the middle must renumber the survivors correctly.
var big = {};
for (var i = 0; i < 200; i++) big["q" + i] = i;
delete big.q100;
delete big.q5;
if (big.q0 !== 0 || big.q199 !== 199 || big.q100 !== undefined ||
    big.q5 !== undefined || Object.keys(big).length !== 198) {
    throw new Error("deleting from the middle corrupted the object");
}

print("delete_prop scaling ok");
