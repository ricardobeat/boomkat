// A store that reaches an inherited setter is cached by the receiver's shape and its chain: the
// cached call must see every change that would make a fresh lookup answer differently.

var log = [];
function Base() { this._v = 0; }
Object.defineProperty(Base.prototype, "v", {
    get: function () { return this._v; },
    set: function (x) { this._v = x; return {}; },
    configurable: true,
});
function put(o, x) { o.v = x; }
function warm(o) { for (var i = 0; i < 300; i++) put(o, i); }

var a = new Base();
warm(a);
log.push(a._v);

// The setter is replaced.
Object.defineProperty(Base.prototype, "v", { set: function (x) { this._v = -x; }, configurable: true });
put(a, 5);
log.push(a._v);
warm(a);

// The receiver gains an own data property, which shadows the setter.
Object.defineProperty(a, "v", { value: 1, writable: true, configurable: true });
put(a, 7);
log.push(a.v, a._v);

// Another object of the first shape still reaches the setter.
var b = new Base();
warm(b);
log.push(b._v);

// The accessor becomes a data property on the prototype: the store creates an own property.
Object.defineProperty(Base.prototype, "v", { value: 3, writable: true, configurable: true });
put(b, 9);
log.push(Object.prototype.hasOwnProperty.call(b, "v"), b.v, b._v);

// The accessor is deleted and defined one level further up.
delete Base.prototype.v;
var c = new Base();
Object.defineProperty(Object.prototype, "v", { set: function (x) { this._v = x * 2; }, configurable: true });
warm(c);
log.push(c._v);
delete Object.prototype.v;
put(c, 4);
log.push(c.v, c._v);

// A prototype is swapped under a cached receiver.
function Other() {}
Other.prototype = { set w(x) { this.got = "other" + x; } };
function Mid() {}
Mid.prototype = { set w(x) { this.got = "mid" + x; } };
function putw(o, x) { o.w = x; }
var d = Object.create(Mid.prototype);
for (var i = 0; i < 300; i++) putw(d, i);
Object.setPrototypeOf(d, Other.prototype);
putw(d, 1);
log.push(d.got);

// A getter-only accessor: a strict store throws, a sloppy one is dropped.
var ro = Object.create({ get r() { return 1; } });
function putr(o) { "use strict"; o.r = 2; }
for (var i = 0; i < 300; i++) { try { putr(ro); } catch (e) { if (i === 299) log.push(e instanceof TypeError); } }

// A setter that throws, one that reads `arguments`, and `this` stores.
var thrower = Object.create({ set t(x) { if (x === 250) throw new Error("at " + x); this.last = x; } });
function putt(o, x) { o.t = x; }
try { for (var i = 0; i < 300; i++) putt(thrower, i); } catch (e) { log.push(e.message, thrower.last); }
var counted = Object.create({ set n(x) { this.count = arguments.length + x; } });
for (var i = 0; i < 300; i++) counted.n = i;
log.push(counted.count);
function Self() { this._s = 0; }
Self.prototype = { set s(x) { this._s = x; }, bump: function (x) { this.s = x; } };
var self = new Self();
for (var i = 0; i < 300; i++) self.bump(i);
log.push(self._s);

// Deep recursion through a setter and a store of an object value.
var deep = Object.create({ set d(x) { if (x.n > 0) this.d = { n: x.n - 1 }; else this.end = x; } });
for (var i = 0; i < 50; i++) deep.d = { n: 20 };
log.push(deep.end.n);

console.log(log.join(" "));
