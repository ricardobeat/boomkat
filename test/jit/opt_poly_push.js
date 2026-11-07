// Array.prototype.push calls built as ARRAY_PUSH nodes, in a function's own body and in inlined
// methods (DeltaBlue's OrderedCollection.add): the result length, growth from empty, then receivers
// and values the node refuses after warmup: undefined, frozen and sealed arrays, a non-writable
// length, array-likes, subclasses, a prototype with an indexed property, a replaced push, and a
// length at the dense limit.
var out = [];
function Coll() { this.elms = []; }
Coll.prototype.add = function (x) { this.elms.push(x); };
Coll.prototype.addLen = function (x) { return this.elms.push(x); };
function fill(c, n) { for (var i = 0; i < n; i++) c.add(i); return c.elms.length; }
function own(a, n) { var s = 0; for (var i = 0; i < n; i++) s += a.push(i * 2); return s; }

var total = 0;
for (var r = 0; r < 2000; r++) total += fill(new Coll(), 1 + (r % 9));
out.push("fill " + total);
var acc = 0;
for (var r = 0; r < 2000; r++) acc += own([], 5);
out.push("own " + acc);
var c = new Coll();
for (var r = 0; r < 3000; r++) c.addLen(r % 3 ? "s" + r : { k: r });
out.push("mixed " + c.elms.length + " " + c.elms[1] + " " + c.elms[3].k);

function tryPush(label, a, v) {
    try { out.push(label + " " + own(a, 2) + " " + a.length); } catch (e) { out.push(label + " threw " + e.constructor.name); }
    var cc = new Coll();
    cc.elms = a;
    try { cc.add(v); out.push(label + "/add " + a.length + " " + a[a.length - 1]); } catch (e) { out.push(label + "/add threw " + e.constructor.name); }
}
tryPush("undef", [1], undefined);
tryPush("frozen", Object.freeze([1, 2]), 3);
tryPush("sealed", Object.seal([1, 2]), 3);
var nw = [1, 2]; Object.defineProperty(nw, "length", { writable: false });
tryPush("nwlen", nw, 3);
tryPush("arraylike", { length: 1, 0: "a", push: Array.prototype.push }, "b");
class Sub extends Array {}
tryPush("subclass", new Sub(), 7);
var holey = [1, , 3]; holey.length = 5;
tryPush("holey", holey, 9);
var named = [1]; named.extra = 1;
tryPush("named", named, 4);
var big = []; big.length = 0xFFFFFF;
tryPush("dense-limit", big, 1);
var proto = Object.create(Array.prototype);
var odd = []; Object.setPrototypeOf(odd, proto);
tryPush("oddproto", odd, 5);
Array.prototype[50] = "inherited";
var a50 = []; for (var i = 0; i < 50; i++) a50[i] = i;
tryPush("protoindex", a50, 6);
delete Array.prototype[50];
var savedPush = Array.prototype.push;
Array.prototype.push = function (x) { this[this.length] = x; return -1; };
tryPush("replaced", [1, 2], 3);
Array.prototype.push = savedPush;
tryPush("restored", [1, 2], 3);
out.push("final " + fill(new Coll(), 4) + " " + own([], 3));
print(out.join("\n"));
