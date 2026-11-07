// Class.create's constructor, one forwarding function shared by every class, inlined at each `new`
// with the initialize of that site's class (the forwarded target is kept per call site), including
// initialize bodies that branch, exits from every level, and a prototype method replaced after warmup.
var out = [];
function show(name, v) { out.push(name + "=" + v); }

var Class = {
    create: function () {
        return function () { this.initialize.apply(this, arguments); };
    }
};

var Vec = Class.create();
Vec.prototype = {
    initialize: function (x, y, z) {
        this.x = (x ? x : 0);
        this.y = (y ? y : 0);
        this.z = (z ? z : 0);
    },
    dot: function (w) { return this.x * w.x + this.y * w.y + this.z * w.z; }
};

var Col = Class.create();
Col.prototype = {
    initialize: function (r, g, b) {
        if (!r) r = 0.0;
        if (!g) g = 0.0;
        if (!b) b = 0.0;
        this.red = r;
        this.green = g;
        this.blue = b;
    }
};

var Pair = Class.create();
Pair.prototype = {
    initialize: function (a, b) { this.a = a; this.b = b; }
};

// A class whose initialize builds another class's object: forwarding inside forwarding.
var Ray = Class.create();
Ray.prototype = {
    initialize: function (x, d) {
        this.position = new Vec(x, 1, 2);
        this.direction = d;
    }
};

function buildV(n) {
    var s = 0;
    for (var i = 0; i < n; i++) { var v = new Vec(i, i & 1, 0); s += v.x + v.y + v.z; }
    return s;
}
// Three levels: the helper, the forwarding constructor, the branching initialize.
function mkC(i) { return new Col(i & 3, i & 1, 2.5); }
function buildC(n) {
    var s = 0;
    for (var i = 0; i < n; i++) { var c = mkC(i); s += c.red + c.green * 3 + c.blue; }
    return s;
}
function buildP(n) {
    var s = 0;
    for (var i = 0; i < n; i++) { var p = new Pair(i, 2); s += p.a * p.b; }
    return s;
}
function build(n) { return buildV(n) + buildC(n) + buildP(n); }

function rays(n) {
    var s = 0;
    var d = new Vec(0, 0, 1);
    for (var i = 0; i < n; i++) {
        var r = new Ray(i & 7, d);
        s += r.position.x + r.position.y * r.position.z + r.direction.z;
    }
    return s;
}

var t = 0;
for (var k = 0; k < 2000; k++) t += build(20);
show("build", t);
var u = 0;
for (var k = 0; k < 2000; k++) u += rays(10);
show("rays", u);

// Missing arguments read undefined in the branching body.
function sparse(n) {
    var s = 0;
    for (var i = 0; i < n; i++) { var v = new Vec(i); s += v.x + v.y + v.z; }
    return s;
}
var sp = 0;
for (var k = 0; k < 1500; k++) sp += sparse(10);
show("sparse", sp);

// The prototype's initialize replaced after warmup: the per-site guard fails over to the new one.
Vec.prototype.initialize = function (x, y, z) { this.x = -x; this.y = y; this.z = z === undefined ? 9 : z; };
show("replaced", build(20) + " " + rays(10));

// An object argument where numbers were seen.
show("object arg", build(3) + " " + new Col({ toString: function () { return "o"; } }, 1, 1).red);

print(out.join("\n"));
