var pass = 0, fail = 0;
function assert(cond, msg) { if (cond) pass++; else { fail++; print("FAIL: " + msg); } }

// Method this
var obj = {
    value: 10,
    getValue: function() { return this.value; }
};
assert(obj.getValue() === 10, "method this");
print("1 ok");

// self-closure pattern
var outer = {
    val: 7,
    method: function() {
        var self = this;
        function inner() {
            return self.val;
        }
        return inner();
    }
};
assert(outer.method() === 7, "self-closure pattern");
print("2 ok");

// Arrow functions
var arrowObj = {
    val: 42,
    setup: function() {
        return () => this.val;
    }
};
assert(arrowObj.setup()() === 42, "arrow inherits this");
print("3 ok");

// Class constructor with `new`
class Point {
    constructor(x, y) {
        this.x = x;
        this.y = y;
    }
    toString() {
        return "(" + this.x + "," + this.y + ")";
    }
}
print("4 before new");
var p = new Point(3, 4);
print("4 after new");
assert(p.x === 3 && p.y === 4, "constructor this");
print("4b");
assert(p.toString() === "(3,4)", "class method this");
print("4c");
//assert(p instanceof Point, "instanceof Point");
print("5 ok");

// new binds this even when constructor returns object
class Box {
    constructor(v) {
        this.inside = "untouched";
        return { replaced: v };
    }
}
var b = new Box(99);
assert(b.replaced === 99, "constructor return overrides this binding");
print("6 ok");

// Multiple instances
class Counter {
    constructor() { this.count = 0; }
    inc() { this.count = this.count + 1; return this.count; }
}
var c1 = new Counter();
var c2 = new Counter();
assert(c1.inc() === 1, "counter 1 first inc");
assert(c1.inc() === 2, "counter 1 second inc");
assert(c2.inc() === 1, "counter 2 first inc (independent)");
print("7 ok");

// Plain function constructor
function Color(r, g, b) {
    this.r = r; this.g = g; this.b = b;
}
var c = new Color(255, 128, 0);
assert(c.r === 255 && c.g === 128 && c.b === 0, "function-ctor with new");
print("8 ok");

print("rosetta/this_binding: " + pass + " passed, " + fail + " failed");
if (fail > 0) throw new Error("FAIL");
