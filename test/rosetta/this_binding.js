// Rosetta Code: This binding
// https://rosettacode.org/wiki/This
// Tests 'this' in methods, constructors, and the self-closure pattern.
// TinyDuck drops Function.prototype.call/apply and the prototype chain;
// this is bound via obj.method() or `new` only.

var pass = 0, fail = 0;
function assert(cond, msg) { if (cond) pass++; else { fail++; print("FAIL: " + msg); } }

// Method this
var obj = {
    value: 10,
    getValue: function() { return this.value; }
};
assert(obj.getValue() === 10, "method this");

// Method this + nested plain function: this does not propagate, capture via
// outer reference instead.
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

// Plain function constructor (no class)
function Color(r, g, b) {
    this.r = r; this.g = g; this.b = b;
}
var c = new Color(255, 128, 0);
assert(c.r === 255 && c.g === 128 && c.b === 0, "function-ctor with new");

// new binds this even when the constructor returns an object
function Box(v) {
    this.inside = "untouched";
    return { replaced: v };
}
var b = new Box(99);
assert(b.replaced === 99, "constructor return overrides this binding");

print("rosetta/this_binding: " + pass + " passed, " + fail + " failed");
if (fail > 0) throw new Error("FAIL");
