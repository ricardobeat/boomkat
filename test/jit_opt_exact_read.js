// An inherited method read that optimized code builds for the one receiver shape its cache has
// held, and whose inlined body trusts that shape: another shape, another prototype behind the
// same shape, a moved epoch and a replaced method must each still read right.
function A(x) { this.x = x; this.y = 1; }
A.prototype.get = function () { return this.x + this.y; };
function B(x) { this.x = x; this.y = 2; }
B.prototype.get = function () { return this.x * this.y; };
function C(x) { this.y = 3; this.x = x; }
C.prototype = Object.create(A.prototype);
function sum(list, n) {
    var t = 0;
    for (var i = 0; i < n; i++) { var o = list[i % list.length]; t += o.get(); }
    return t;
}
function sum2(list, n) {
    var t = 0;
    for (var i = 0; i < n; i++) { var o = list[i % list.length]; t += o.get(); }
    return t;
}
var r = [];
var as = [new A(1), new A(2), new A(3)];
r.push(sum(as, 60000));
// Another shape first, for a read built before any second receiver.
r.push(sum2(as, 60000), sum2([new C(4), new A(1)], 60000), sum2([new B(7), new C(2)], 60000));
// Same fields in the same order under another prototype.
r.push(sum([new A(1), new B(5), new A(2)], 60000));
// Another shape, through a longer chain.
r.push(sum([new C(4), new A(1)], 60000));
// The epoch moves, then the method is replaced, then shadowed on one receiver.
A.prototype.extra = 1;
r.push(sum(as, 60000));
A.prototype.get = function () { return this.x - this.y; };
r.push(sum(as, 60000));
as[1].get = function () { return 100; };
r.push(sum(as, 60000));
Object.setPrototypeOf(as[0], B.prototype);
r.push(sum(as, 60000));
print(r.join(" "));
