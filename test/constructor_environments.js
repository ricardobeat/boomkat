function equal(actual, expected, label) {
    if (actual !== expected) throw new Error(label + ": " + actual + " !== " + expected);
}

var x = "outer";
class Base {
    constructor(x) { this.x = x; this.target = new.target; }
}
class Derived extends Base {
    constructor(x) { super(x); this.y = x + 1; }
}
equal(new Base(3).x, 3, "base parameter");
var derived = new Derived(5);
equal(derived.x, 5, "super parameter");
equal(derived.y, 6, "derived parameter");
equal(derived.target, Derived, "new.target through super");
equal(x, "outer", "enclosing binding");

class Defaults {
    constructor(value = 11, ...rest) {
        this.value = value;
        this.rest = rest;
    }
}
equal(new Defaults().value, 11, "default parameter");
equal(new Defaults(1, 2, 3).rest.length, 2, "rest parameter");

function Sloppy(value) {
    arguments[0] = 13;
    this.value = value;
}
equal(new Sloppy(1).value, 13, "mapped arguments");

var object = { value: 19 };
var WithConstructor;
with (object) {
    WithConstructor = function () { this.value = value; };
}
equal(new WithConstructor().value, 19, "captured with scope");
equal(object.value, 19, "with object preserved");

var Named = function Self() { this.self = Self; };
equal(new Named().self, Named, "constructor name binding");
print("PASS constructor environments");
