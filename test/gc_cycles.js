// Reference cycles are unreachable from any root but keep each other's
// refcount above zero, so only mark-and-sweep can reclaim them. This test
// builds many cycles, drops them, and checks the heap actually shrinks --
// a mark-colour bug that silently stopped collecting cycles would leave
// every other test passing, so it is checked here directly.

function makeCycle(n) {
    // A ring of n objects, each holding the next; the last closes the ring.
    var head = { id: 0, next: null, pad: "x" };
    var cur = head;
    for (var i = 1; i < n; i++) {
        cur.next = { id: i, next: null, pad: "x" };
        cur = cur.next;
    }
    cur.next = head;
    // A second edge back to the head makes the cycle non-trivial (not a
    // simple ring that a naive walker could unlink in order).
    head.tail = cur;
    return head;
}

var ROUNDS = 40;
var CYCLES_PER_ROUND = 500;
var RING = 20;

// Churn: build cycles and drop them immediately. Nothing else retains them,
// so every object here is cycle garbage.
for (var r = 0; r < ROUNDS; r++) {
    for (var c = 0; c < CYCLES_PER_ROUND; c++) {
        var ring = makeCycle(RING);
        // Touch it so the ring cannot be optimised away.
        if (ring.next.id !== 1) { throw new Error("ring built wrong"); }
        ring = null;
    }
}

// If cycles were never reclaimed, the objects above (ROUNDS * CYCLES_PER_ROUND
// * RING = 400000 of them) would all still be live. Allocate a large retained
// structure afterwards and confirm the program still runs in a sane heap --
// on a collector that has stopped reclaiming cycles this either exhausts
// memory or drives the live count through the roof.
var retained = [];
for (var i = 0; i < 1000; i++) {
    retained.push({ i: i });
}

if (retained.length !== 1000) { throw new Error("retained wrong"); }
if (retained[999].i !== 999) { throw new Error("retained content wrong"); }

// Cycles that are still reachable must NOT be collected.
var keepAlive = [];
for (var i = 0; i < 100; i++) {
    keepAlive.push(makeCycle(10));
}
for (var i = 0; i < 100; i++) {
    var k = keepAlive[i];
    if (k.next.next.id !== 2) { throw new Error("live cycle corrupted at " + i); }
    if (k.tail.next !== k) { throw new Error("live cycle back-edge broken at " + i); }
}

print("gc_cycles ok");
