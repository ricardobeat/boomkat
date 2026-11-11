// Field and element stores from optimized code into a long-lived owner: the
// owner is promoted while the loop runs, the values are young objects, strings
// and numbers, and collections run throughout.
function Node(v) { this.v = v; this.next = null; this.tag = "t" + (v & 7); }
function Holder() { this.cur = null; this.name = "n"; this.count = 0; this.slots = [null, null, null, "s"]; }
Holder.prototype.step = function (i) {
  var n = new Node(i);
  n.next = this.cur;
  this.cur = n;
  this.name = n.tag;
  this.count = i;
  this.slots[i & 3] = n;
  this.slots[(i + 1) & 3] = n.tag;
  this.slots[(i + 2) & 3] = i * 0.5;
  if ((i & 63) == 0) this.cur.next = null;
  return n.v;
};
var h = new Holder();
var sum = 0, junk = [];
for (var i = 0; i < 300000; i++) {
  sum += h.step(i);
  if ((i & 1023) == 0) junk = [];
  junk.push({ i: i });
}
var depth = 0;
for (var n = h.cur; n != null; n = n.next) depth++;
console.log(sum, depth, h.name, h.count, h.cur.v, typeof h.slots[0], typeof h.slots[1], typeof h.slots[2], typeof h.slots[3]);
