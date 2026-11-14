// A field read the optimized body compiled for one receiver shape exits when other shapes arrive.
// The rebuild learns the shapes its cache can hold; past that, after repeated exits, the next build
// lowers the site generically, and every phase keeps its result.
function read(o) {
    var s = 0;
    for (var i = 0; i < 4; i++) s += o.x + o.y;
    return s;
}
// Kind k is an object with k leading properties before x and y: a shape of its own.
function mk(kind, i) {
    var o = {};
    for (var k = 0; k < kind; k++) o["p" + k] = k;
    o.x = i;
    o.y = kind;
    return o;
}
var total = 0;
for (var phase = 0; phase < 8; phase++) {
    for (var i = 0; i < 3000; i++) total += read(mk(phase < 2 ? 0 : i % (phase + 1), i));
}
print(total);
// The same through a method and a prototype read, which exits on other classes' instances.
function A() { this.v = 1; }
A.prototype.get = function () { return this.v; };
function B() { this.u = 0; this.v = 2; }
B.prototype.get = function () { return this.v * 10; };
function call(o) { return o.get() + o.v; }
var t2 = 0;
for (var i = 0; i < 6000; i++) t2 += call(new A());
for (var i = 0; i < 6000; i++) t2 += call(i & 1 ? new A() : new B());
print(t2);
