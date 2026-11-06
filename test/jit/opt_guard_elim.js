// Redundant shape guards between field nodes on one register: each case changes the receiver or
// its shape between two accesses in a way the later access must still see.
var out = [];

function twice(o, n) {
    var s = 0;
    for (var i = 0; i < n; i++) s += o.a + o.a + o.b;
    return s;
}
out.push(twice({ a: 1, b: 2 }, 500), twice({ a: 1, b: 2 }, 500));

function rwr(o, n) {
    var s = 0;
    for (var i = 0; i < n; i++) {
        s += o.a;
        o.a = i;
        s += o.a;
    }
    return s;
}
out.push(rwr({ a: 1, b: 2 }, 500), rwr({ a: 1, b: 2 }, 500));

// A call between two reads gives the object a new property: the second read's shape differs.
function grow(o) { o.z = 1; delete o.a; }
function viaCall(n) {
    var o = { a: 1, b: 2 }, s = 0;
    for (var i = 0; i < n; i++) {
        s += o.b;
        if (i == 300) grow(o);
        s += o.b;
        o.b = i;
        s += o.b;
        if (i == 400) o = { b: 5, a: 9 };
    }
    return s;
}
out.push(viaCall(500), viaCall(500));

// The register is replaced between reads.
function swap(p, q, n) {
    var o = p, s = 0;
    for (var i = 0; i < n; i++) {
        s += o.a;
        o = (i % 3 == 0) ? q : p;
        s += o.a;
        o.a = s & 7;
    }
    return s;
}
out.push(swap({ a: 1, b: 2 }, { a: 3, b: 4 }, 500), swap({ a: 1, b: 2 }, { b: 4, a: 3 }, 500));

// `this` reads across a method that deletes from this.
function Box() { this.x = 1; this.y = 2; this.z = 3; }
Box.prototype.run = function (n) {
    var s = 0;
    for (var i = 0; i < n; i++) {
        s += (this.x | 0) + this.y;
        if (i == 250) this.shrink();
        s += this.y + this.z;
        this.y = i;
        s += this.y;
    }
    return s;
};
Box.prototype.shrink = function () { delete this.x; };
out.push(new Box().run(500), new Box().run(500));

// A proxy receiver after plain ones.
function pread(o, n) {
    var s = 0;
    for (var i = 0; i < n; i++) s += o.a + o.a;
    return s;
}
out.push(pread({ a: 1 }, 400), pread(new Proxy({ a: 2 }, {}), 400));

print(out.join(","));
