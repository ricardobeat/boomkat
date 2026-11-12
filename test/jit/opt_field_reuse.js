// A field read again with nothing in between that can change it takes the node of the earlier read
// or store (OptBuild.held_field). A store through another name for the object, a call that runs
// code, a merge where the paths disagree, and a register rewritten in between all read it afresh.
function Node(v) { this.v = v; this.next = null; this.n = 0; }
function alias(a, b, k) {
  var x = a.v;
  b.v = k;
  return x + a.v;
}
function forward(o, k) {
  o.n = k * 2;
  return o.n + o.n;
}
function across(o, k) {
  var x = o.v;
  if (k & 1) { o.v = x + 1; } else { o.n = x; }
  return o.v + x;
}
function rewrite(o, p) {
  var r = o;
  var x = r.v;
  r = p;
  return x + r.v;
}
var calls = 0;
function bump(o) { calls++; o.v++; }
function called(o, f) {
  var x = o.v;
  f(o);
  return x + o.v;
}
function walk(head) {
  var s = 0;
  for (var c = head; c != null; c = c.next) s += c.v + c.v;
  return s;
}
var a = new Node(1);
var b = new Node(2);
var list = new Node(1);
list.next = new Node(2);
list.next.next = new Node(3);
var sum = 0;
for (var i = 0; i < 30000; i++) {
  a.v = i; b.v = 7;
  sum += alias(a, (i & 3) == 0 ? a : b, i & 7);
  sum += forward(a, i & 15);
  sum += across(b, i);
  sum += rewrite(a, b);
  sum += called(a, bump);
  sum += walk(list);
}
print(sum, calls, a.v, b.v, b.n);
