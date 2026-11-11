// Property adds through a warm cache must notice every change to the
// prototype chain: a setter, a read-only property, a new link, a swapped
// prototype, and a deleted then re-added property.
var log = [];
function Base() {}
function Mid() {}
Mid.prototype = Object.create(Base.prototype);
function P(v) { this.a = v; this.b = v + 1; this.c = v + 2; }
P.prototype = Object.create(Mid.prototype);
function make(n) { var s = 0; for (var i = 0; i < n; i++) { var o = new P(i); s += o.a + o.b + o.c; } return s; }
function own(o) { return Object.keys(o).join(""); }
log.push(make(20000));
Object.defineProperty(Base.prototype, "b", { set: function (v) { this._b = v * 2; }, get: function () { return this._b; }, configurable: true });
var o1 = new P(1);
log.push(own(o1), o1.b, make(20000));
delete Base.prototype.b;
var o2 = new P(1);
log.push(own(o2), o2.b, make(20000));
Object.defineProperty(Mid.prototype, "c", { value: 7, writable: false, configurable: true });
var o3 = new P(1);
log.push(own(o3), o3.c, make(20000));
delete Mid.prototype.c;
Mid.prototype.c = 9;
var o4 = new P(1);
log.push(own(o4), o4.c, make(20000));
Object.setPrototypeOf(Mid.prototype, { set a(v) { this._a = v; }, get a() { return 100; } });
var o5 = new P(1);
log.push(own(o5), o5.a, make(2000));
Object.setPrototypeOf(Mid.prototype, Base.prototype);
// Receivers of one shape with different prototypes at one site.
function fill(o, v) { o.x = v; o.y = v; return o; }
var pa = { set y(v) { this.z = v; } }, pb = {};
var n = 0;
for (var i = 0; i < 20000; i++) {
  var r = fill(Object.create((i & 1) ? pa : pb), i);
  if (((i & 1) != 0) == ("z" in r) && ((i & 1) == 0) == r.hasOwnProperty("y")) n++;
}
log.push(n);
console.log(log.join(" "));
