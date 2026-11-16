// A derived constructor's non-literal parameter defaults run before super()
// binds `this`. They must not read `this` unless the default itself does.

var failures = 0;
function check(name, actual, expected) {
    if (actual !== expected) {
        print("FAIL: " + name + " — expected " + expected + ", got " + actual);
        failures++;
    }
}

class A {}

class C extends A {
    constructor(x = Math.PI, y = x, z = [1], w = (() => 2)()) {
        super();
        this.r = [x === Math.PI, y === x, z.length, w].join();
    }
}
check("non-literal defaults", new C().r, "true,true,1,2");

class ThisDefault extends A { constructor(x = this) { super(); } }
var threw = "none";
try { new ThisDefault(); } catch (e) { threw = e.constructor.name; }
check("`this` default before super()", threw, "ReferenceError");

class SuperDefault extends A { constructor(x = super()) { this.ok = x === this; } }
check("super() default", new SuperDefault().ok, true);

class LazyThis extends A { constructor(f = () => this) { super(); this.ok = f() === this; } }
check("arrow default reads `this` after super()", new LazyThis().ok, true);

class NewTarget extends A { constructor(t = new.target) { super(); this.ok = t === NewTarget; } }
check("new.target default", new NewTarget().ok, true);

class ArrowBefore extends A {
    constructor() {
        var f = (q = Math.PI) => q;
        this_ok = f() === Math.PI;
        super();
    }
}
var this_ok = false;
new ArrowBefore();
check("arrow default before super()", this_ok, true);

class EvalBefore extends A {
    constructor() {
        eval("var g = (q = Math.PI) => q; this_ok = g() === Math.PI;");
        super();
    }
}
this_ok = false;
new EvalBefore();
check("eval arrow default before super()", this_ok, true);

class Method extends A { m(x = this) { return x === this; } }
check("derived method default `this`", new Method().m(), true);

if (failures > 0) {
    throw new Error(failures + " check(s) failed");
}
print("OK");
