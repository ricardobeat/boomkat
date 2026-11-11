// Optimized code that reads objects out of fields, globals and closures while the collector is
// marking: each read publishes an object the mark may not have reached yet, which is marked and
// kept rather than left to the baseline code. The graph is rebuilt constantly so that mark phases
// overlap the hot loops, and every value read is checked.
var out = [];
function Cell(v, next) { this.v = v; this.next = next; this.box = { v: v }; }
var root = null, table = [];
function build(n) {
    var head = null;
    for (var i = 0; i < n; i++) head = new Cell(i, head);
    return head;
}
function sum(list) {
    var s = 0;
    for (var c = list; c !== null; c = c.next) s += c.v + c.box.v;
    return s;
}
function pick(i) { var c = table[i % table.length]; return c.box; }
function churn(rounds) {
    var acc = 0;
    for (var r = 0; r < rounds; r++) {
        root = build(200 + (r & 31));
        table[r & 63] = root;
        acc += sum(root) + pick(r).v;
        var keep = root.next.next;
        acc += keep.box.v + sum(keep);
    }
    return acc;
}
var counter = (function () {
    var held = { n: 0, list: null };
    return function (k) { held.list = build(k); held.n += sum(held.list); return held; };
})();
for (var k = 0; k < 12; k++) {
    out.push(churn(400));
    out.push(counter(300 + k).n);
}
console.log(out.join("\n"));
