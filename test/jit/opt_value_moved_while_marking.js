// Optimized code that reads an object out of a field into a register, then takes it out of that
// field before the value reaches the window: while the collector marks, the store into the window
// is the only thing that can mark it. Garbage is made constantly so that mark phases overlap the
// hot loop, and every moved object is checked after it has been kept.
var out = [];
function Node(v) { this.v = v; this.box = { v: v, tag: "n" + (v & 7) }; this.next = null; }
var keep = [];
function move(holder, i) {
    var taken = holder.box;
    holder.box = { v: -1, tag: "fresh" };
    keep[i & 255] = taken;
    return taken.v;
}
function churn(rounds) {
    var acc = 0;
    var holder = new Node(0);
    for (var r = 0; r < rounds; r++) {
        holder.box = { v: r, tag: "t" + (r & 15) };
        var junk = [];
        for (var j = 0; j < 40; j++) junk.push({ a: j, b: [j, j + 1] });
        acc += move(holder, r) + junk.length;
    }
    return acc;
}
var total = 0;
for (var round = 0; round < 30; round++) total += churn(3000);
var bad = 0;
for (var k = 0; k < keep.length; k++) {
    var b = keep[k];
    if (typeof b !== "object" || b.v < 0 || b.tag !== "t" + (b.v & 15)) bad++;
}
out.push(total, keep.length, bad);
console.log(out.join(" "));
