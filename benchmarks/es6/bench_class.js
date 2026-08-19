// Class construction and method dispatch. Classes route through the same shape
// and prototype machinery as ES5 constructors, plus per-class bookkeeping for
// methods, getters and fields.
var N = 1000000;

class Point {
    constructor(x, y) { this.x = x; this.y = y; }
    get magnitude() { return this.x * this.x + this.y * this.y; }
    translate(dx, dy) { this.x += dx; this.y += dy; return this; }
}

class Point3D extends Point {
    constructor(x, y, z) { super(x, y); this.z = z; }
    get magnitude() { return super.magnitude + this.z * this.z; }
}

function constructAndCall(n) {
    let s = 0;
    for (let i = 0; i < n; i++) { s += new Point(i, i).magnitude; }
    return s;
}

function methodCalls(n) {
    const p = new Point(0, 0);
    for (let i = 0; i < n; i++) { p.translate(1, 1); }
    return p.x;
}

// A derived class exercises super() and the derived-constructor return rules.
function derived(n) {
    let s = 0;
    for (let i = 0; i < n; i++) { s += new Point3D(i, i, i).magnitude; }
    return s;
}

var r = 0;
r += constructAndCall(N);
r += methodCalls(N);
r += derived(N / 2);
if (r === 0) throw new Error("optimized away");
