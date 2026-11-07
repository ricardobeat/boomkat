// A field read the optimized body compiled for one receiver shape exits when other shapes arrive;
// after repeated exits the next build lowers the site generically, and every phase keeps its result.
function read(o) {
    var s = 0;
    for (var i = 0; i < 4; i++) s += o.x + o.y;
    return s;
}
function mk(kind, i) {
    var o = {};
    if (kind === 0) { o.x = i; o.y = 1; }
    else if (kind === 1) { o.y = 2; o.x = i; }
    else if (kind === 2) { o.z = 0; o.x = i; o.y = 3; }
    else { o.w = 0; o.z = 0; o.y = 4; o.x = i; }
    return o;
}
var total = 0;
for (var phase = 0; phase < 8; phase++) {
    for (var i = 0; i < 3000; i++) total += read(mk(phase < 2 ? 0 : (phase & 3), i));
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
