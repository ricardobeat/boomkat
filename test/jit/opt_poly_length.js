// `length` reads in the optimizing tier: an array's length in a loop condition and in inlined
// methods (OrderedCollection.size of DeltaBlue), then receivers the read did not see while warming
// up: strings, objects with an own or inherited `length`, typed arrays, proxies, arguments, and an
// array longer than the int32 range.
var out = [];

function Coll() { this.elms = []; }
Coll.prototype.add = function (x) { this.elms.push(x); };
Coll.prototype.size = function () { return this.elms.length; };
Coll.prototype.at = function (i) { return this.elms[i]; };
function Holder(c) { this.v = c; }
Holder.prototype.size = function () { return this.v.size(); };
Holder.prototype.at = function (i) { return this.v.at(i); };

function total(h) {
    var s = 0;
    for (var i = 0; i < h.size(); i++) s += h.at(i);
    return s;
}
function plainLen(a) {
    var s = 0;
    for (var i = 0; i < a.length; i++) s += i;
    return s + a.length;
}

var c = new Coll();
for (var k = 0; k < 20; k++) c.add(k);
var h = new Holder(c);
var t = 0;
for (var r = 0; r < 3000; r++) t += total(h);
out.push("total " + t);
// The length changes between calls and inside the loop.
for (var r = 0; r < 50; r++) { c.add(r); c.elms.pop(); c.elms.pop(); c.add(1); }
out.push("after " + total(h) + " " + c.size());

var acc = 0;
for (var r = 0; r < 3000; r++) acc += plainLen([1, 2, 3, r]);
out.push("plain " + acc);
// Other receivers after warmup.
out.push("string " + plainLen("hello"));
out.push("object " + plainLen({ length: 4 }));
out.push("inherited " + plainLen(Object.create({ length: 3 })));
out.push("typed " + plainLen(new Int16Array(5)));
out.push("proxy " + plainLen(new Proxy([1, 2], {})));
out.push("args " + (function () { return plainLen(arguments); })(1, 2, 3));
out.push("double " + plainLen({ length: 2.5 }));
var big = [];
big.length = 4294967295;
try { out.push("big " + big.length + " " + (big.length > 2147483647)); } catch (e) { out.push("big threw " + e); }
function bigLen(a) { return a.length + 1; }
for (var r = 0; r < 3000; r++) bigLen([r]);
out.push("biglen " + bigLen(big));
// A collection whose elements become a string: size() then reads a string's length.
var sc = new Coll();
sc.elms = "abcdef";
out.push("strcoll " + h.size() + " " + new Holder(sc).size());
for (var r = 0; r < 3000; r++) t += new Holder(sc).size();
out.push("strcoll2 " + t);
print(out.join("\n"));
