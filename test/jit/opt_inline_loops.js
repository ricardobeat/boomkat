// A callee with a loop is inlined: its back edge polls from records of the inlined frames, which a
// collection there must see (the objects the loop holds survive it), and exits from inside the
// loop leave the frames to their baseline code mid-loop.
var out = [];
function Q(v) { this.v = v; this.link = null; }
// Walks to the end of the queue: a loop in the callee.
Q.prototype.addTo = function (queue) {
    this.link = null;
    if (queue == null) return this;
    var peek, next = queue;
    while ((peek = next.link) != null) next = peek;
    next.link = this;
    return queue;
};
function sum(a, n) { var s = 0; for (var i = 0; i < n; i++) s += a[i]; return s; }
// A body that alone holds a string and an object across its own long loop: a collection at the
// loop's poll must keep them. The caller's allocations keep collections coming.
function Holder(k) { this.peer = new Q(k); this.name = "n" + k; }
// Its unused parameters put its registers past the caller's frame and scratch slots.
Holder.prototype.work = function (arr, n, p2, p3, p4, p5, p6, p7) {
    var keep = this.peer;
    var name = this.name;
    this.peer = null;
    this.name = null;
    var s = 0;
    for (var i = 0; i < n; i++) s += arr[i % arr.length] & keep.v;
    this.peer = keep;
    this.name = name;
    return s + keep.v;
};
function drive(n) {
    var acc = 0, arr = [1, 2, 3, 4, 5];
    for (var r = 0; r < n; r++) {
        var q = new Q(1);
        q = new Q(2).addTo(q);
        q = new Q(3).addTo(q);
        acc += q.link.link.v + sum(arr, r & 3);
    }
    return acc;
}
function heavy(h, arr, rounds) {
    var acc = 0;
    for (var r = 0; r < rounds; r++) {
        if ((r & 15) == 0) { h.peer = new Q(r & 255); h.name = "name:" + r + ":" + rounds; }
        acc += h.work(arr, 300 + (r & 7), 0, 0, 0, 0, 0, 0) + new Q(r).v + h.name.length;
    }
    return acc;
}
var t = 0;
for (var k = 0; k < 40; k++) t += drive(1000);
var h = new Holder(7);
var w = 0;
var big = [];
for (var i = 0; i < 64; i++) big.push(i * 3);
for (var k = 0; k < 3000; k++) w += heavy(h, big, 4);
out.push(t, w);
// The array turns out to hold a hole and a string after the code was built: exits mid-loop.
var late = [1, 2, , "x", 5];
var tail = [];
for (var k = 0; k < 3; k++) tail.push(sum(late, 5));
out.push(tail.join(","));
console.log(out.join(" "));
