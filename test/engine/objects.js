// Multiple distinct objects
// Create several distinct objects; verify they don't collide.

var pass = 0, fail = 0;
function assert(c, m) { if (c) pass++; else { fail++; print("FAIL: " + m); } }

function Point(x, y) { this.x = x; this.y = y; }
Point.prototype.toString = function () { return "(" + this.x + "," + this.y + ")"; };

function Circle(x, y, r) { Point.call(this, x, y); this.r = r; }
Circle.prototype = Object.create(Point.prototype);
Circle.prototype.constructor = Circle;
Circle.prototype.area = function () { return Math.PI * this.r * this.r; };

function Rect(x, y, w, h) { Point.call(this, x, y); this.w = w; this.h = h; }
Rect.prototype = Object.create(Point.prototype);
Rect.prototype.constructor = Rect;
Rect.prototype.area = function () { return this.w * this.h; };

var pts = [];
for (var i = 0; i < 5; i++) pts.push(new Point(i, i * 2));

// All distinct
for (var i = 0; i < pts.length; i++) {
    for (var j = i + 1; j < pts.length; j++) {
        assert(pts[i] !== pts[j], "points[" + i + "] !== [" + j + "]");
    }
}

// Point fields
assert(pts[2].x === 2 && pts[2].y === 4, "pts[2]=(2,4)");
assert(pts[0].toString() === "(0,0)", "pts[0].toString()");

// Circle inheritance
var c = new Circle(1, 2, 3);
assert(c.x === 1 && c.y === 2 && c.r === 3, "circle fields");
assert(c instanceof Circle, "c instanceof Circle");
assert(c instanceof Point, "c instanceof Point (via proto chain)");
var ca = c.area();
assert(ca > 28.2 && ca < 28.3, "circle area = " + ca);

// Rect
var r = new Rect(0, 0, 4, 5);
assert(r.area() === 20, "rect area");
assert(r instanceof Rect && r instanceof Point, "rect inheritance");

print("engine/objects: " + pass + " passed, " + fail + " failed");
if (fail > 0) throw new Error("FAIL");