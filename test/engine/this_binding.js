// This binding
// Tests 'this' in methods, constructors, call/apply, and loose mode.

var pass = 0, fail = 0;
function assert(cond, msg) { if (cond) pass++; else { fail++; print("FAIL: " + msg); } }

// Method this
var obj = {
    value: 10,
    getValue: function() { return this.value; }
};
assert(obj.getValue() === 10, "method this");

// Constructor this
function Point(x, y) {
    this.x = x;
    this.y = y;
}
Point.prototype.toString = function() {
    return "(" + this.x + "," + this.y + ")";
};
var p = new Point(3, 4);
assert(p.x === 3 && p.y === 4, "constructor this");
assert(p.toString() === "(3,4)", "prototype method this");

// call with explicit this
function getX() { return this.x; }
assert(getX.call(p) === 3, "call binds this");

// apply with args
function add(a, b) { return this.base + a + b; }
var ctx = { base: 100 };
assert(add.apply(ctx, [10, 20]) === 130, "apply binds this + args");
assert(add.call(ctx, 10, 20) === 130, "call binds this + args");

// Nested function: this doesn't propagate
var outer = {
    val: 7,
    method: function() {
        var self = this;
        function inner() {
            return self.val; // closure captures self, not this
        }
        return inner();
    }
};
assert(outer.method() === 7, "self-closure pattern");

// Constructor without new (sloppy mode: this is global, returns object with fields)
function Color(r, g, b) {
    this.r = r; this.g = g; this.b = b;
}
var c = new Color(255, 128, 0);
assert(c.r === 255 && c.g === 128 && c.b === 0, "constructor assigns");

print("engine/this_binding: " + pass + " passed, " + fail + " failed");
if (fail > 0) throw new Error("FAIL");
