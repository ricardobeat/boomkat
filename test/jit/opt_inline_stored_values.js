// Values of an inlined body two levels deep live in slots beyond the caller's frame. Where one
// reaches a join or outlives a real call it is stored there: a collection inside the call must keep
// it, and an exit must find it in its slot.
var out = [];
function Node(v, next) { this.v = v; this.next = next; }
// A loop keeps it from being inlined: a real call, which also makes garbage.
var sink = [];
function churn(k) { for (var i = 0; i < 1; i++) sink[k & 31] = { a: [k, k + 1], s: "x" + (k & 7) }; return k & 1; }
function Pick(a, b) { this.a = a; this.b = b; }
// The object chosen at the join is held across the call.
Pick.prototype.take = function (k) {
    var o = (k & 1) ? this.a : this.b;
    var c = churn(k);
    return o.v + o.next.v + c;
};
Pick.prototype.nested = function (k) { var r = this.take(k); return r + this.a.v; };
// Built in the body, then held across the call.
Pick.prototype.build = function (k) {
    var n = new Node(k, this.a);
    churn(k);
    return n.v + n.next.v;
};
function run(p, n) {
    var acc = 0;
    for (var k = 0; k < n; k++) acc += p.nested(k) + p.build(k);
    return acc;
}
var p = new Pick(new Node(1, new Node(2, null)), new Node(3, new Node(4, null)));
var acc = 0;
for (var r = 0; r < 30; r++) acc += run(p, 400);
out.push(acc);
// The chosen object turns out to have no `next` after the code was built: an exit after the call.
p.b = new Node(5, null);
var late = [];
for (var k = 0; k < 4; k++) { try { late.push(run(p, 2)); } catch (e) { late.push(e.constructor.name); } }
out.push(late.join(","));
console.log(out.join(" "));
