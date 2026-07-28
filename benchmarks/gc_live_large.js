// Steady large live set (~120k objects) with continuous garbage churn.
// Models a UI-style workload: a big retained tree plus per-frame temporaries.
// Used to measure GC pause time against a live set that the mark and sweep
// phases must both walk in full.

var RETAINED = 120000;
var live = new Array(RETAINED);
for (var i = 0; i < RETAINED; i++) {
    live[i] = { id: i, next: null, payload: i * 2 };
}
// Chain them so the mark phase does real pointer-chasing rather than a
// flat array scan.
for (var i = 0; i + 1 < RETAINED; i++) {
    live[i].next = live[i + 1];
}

// Frame loop: allocate and drop short-lived objects, replacing a slice of the
// retained set each frame so the live set stays roughly constant.
var FRAMES = 60;
var PER_FRAME = 20000;
var sink = 0;
for (var f = 0; f < FRAMES; f++) {
    for (var j = 0; j < PER_FRAME; j++) {
        var tmp = { a: j, b: { c: j } };
        sink += tmp.b.c;
    }
    var base = (f * 1000) % (RETAINED - 1000);
    for (var k = 0; k < 1000; k++) {
        live[base + k] = { id: base + k, next: live[base + k].next, payload: k };
    }
}
print("sink=" + sink + " live=" + live.length);
