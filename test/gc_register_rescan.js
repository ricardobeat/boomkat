// Stores to registers carry no write barrier.
//
// A value loaded out of the heap into a frame the collector has already
// scanned, and then dropped from the heap, is reachable only from that frame.
// The collector rescans the frames before it sweeps, so it survives.

var pass = 0;
var fail = 0;

function eq(actual, expected, msg) {
    if (actual === expected) { pass++; }
    else { fail++; print('FAIL: ' + msg + ' (got ' + actual + ', want ' + expected + ')'); }
}

function churn(n) {
    var junk = [];
    for (var i = 0; i < n; i++) junk.push({ a: i, b: [i, i + 1], c: 'k' + i });
    return junk.length;
}

// Each round moves a fresh object out of a holder into a local, empties the
// holder, and allocates until collections run while the local is the only root.
function round(seed) {
    var holder = { slot: { id: seed, tail: [seed, seed * 2] } };
    var held = holder.slot;
    holder.slot = null;
    churn(400);
    return held.id + held.tail[1];
}
var sum = 0;
for (var r = 0; r < 300; r++) sum += round(r);
eq(sum, 3 * 299 * 300 / 2, 'objects held only by a register survive collections');

// A register copied between frames through arguments and returns.
function pass2(o) { churn(200); return o; }
function chain(o) { return pass2(pass2(o)); }
var ok = true;
for (var r = 0; r < 200; r++) {
    var made = { v: r, w: { x: r } };
    var back = chain(made);
    made = null;
    ok = ok && back.v === r && back.w.x === r;
}
eq(ok, true, 'objects passed through frames survive');

print('gc_register_rescan: ' + pass + ' passed, ' + fail + ' failed');
if (fail > 0) { print('SOME TESTS FAILED'); throw new Error('FAIL'); }
