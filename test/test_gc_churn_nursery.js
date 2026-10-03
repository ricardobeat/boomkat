// A retained set of ~10k objects with mostly-garbage churn runs minor cycles.
// Old objects that point at young ones, replaced and cleared slots, and
// callbacks that allocate must all keep what is still reachable.
function check(label, got, want) {
    if (got !== want) throw new Error(label + ": got " + String(got) + ", want " + String(want));
}

var retained = [];
for (var i = 0; i < 10000; i++) retained.push({ id: i, link: null, tag: "r" + (i % 50) });

var sum = 0;
for (var round = 0; round < 400; round++) {
    var batch = Array.from({ length: 256 }, function (_, k) {
        return { k: k, owner: retained[(round * 256 + k) % retained.length], pad: [k, k + 1] };
    });
    // Old-to-young stores: every few rounds a retained object points at a fresh one.
    var target = retained[(round * 37) % retained.length];
    target.link = { round: round, payload: { k: batch[round % 256].k } };
    sum += batch.reduce(function (acc, o) { return acc + o.k + o.owner.id * 0; }, 0);
}
check("sum", sum, 400 * (255 * 256 / 2));

// Links written during churn survive later cycles.
var live = 0;
for (var j = 0; j < retained.length; j++) {
    var l = retained[j].link;
    if (l !== null) {
        check("link payload " + j, l.payload.k, l.round % 256);
        live++;
    }
}
check("live links", live > 0, true);

// A retained object's slot overwritten and cleared while young objects churn.
var holder = { slot: null };
retained.push(holder);
for (var r = 0; r < 2000; r++) {
    holder.slot = { n: r, inner: [r] };
    for (var t = 0; t < 40; t++) ({ t: t, a: [t] });
    if (r % 500 === 0) check("slot " + r, holder.slot.inner[0], r);
}
check("final slot", holder.slot.n, 1999);
print("ok");
