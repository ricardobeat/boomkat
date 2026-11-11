// A field store whose value is a property read: optimized code keeps the value
// in a register when it is an object, and leaves for strings and other values.
function Node(v, next) { this.v = v; this.next = next; this.cur = null; this.tag = null; }
function advance(l) { l.cur = l.cur.next; }
function copyTag(a, b) { a.tag = b.tag; }
var c = new Node(3, null), b = new Node(2, c), a = new Node(1, b);
c.next = a;
var l = new Node(0, null);
l.cur = a;
var sum = 0;
for (var i = 0; i < 300000; i++) { advance(l); sum += l.cur.v; }
console.log(sum, l.cur.v);
var s = new Node(0, null), d = new Node(0, null);
var tags = ["x" + sum, 1.5, null, undefined, a, true, 7];
var out = [];
for (var i = 0; i < 300000; i++) {
  s.tag = tags[i % 7];
  copyTag(d, s);
  if (i > 299992) out.push(typeof d.tag === "object" && d.tag ? "node" + d.tag.v : String(d.tag));
}
console.log(out.join());
// Constant stores over numbers, objects and strings.
function reset(n, flag) { n.cur = null; n.tag = undefined; n.v = flag ? true : false; n.next = null; }
var r = new Node(1, a), kinds = [a, "s" + sum, 2.5, null];
var seen = 0;
for (var i = 0; i < 300000; i++) {
  r.cur = kinds[i & 3]; r.tag = kinds[(i + 1) & 3]; r.next = kinds[(i + 2) & 3];
  reset(r, (i & 1) == 0);
  if (r.cur === null && r.tag === undefined && r.next === null && r.v === ((i & 1) == 0)) seen++;
}
console.log(seen);
