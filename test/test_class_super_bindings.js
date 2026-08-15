// Regression: multiple classes with `extends` in one function scope must not
// clobber each other's __super__ / __static_super__ bindings.

var pass = 0;
var fail = 0;

function assert(cond, msg) {
    if (cond) { pass++; } else { fail++; print('FAIL: ' + msg); }
}

// --- 1. Multiple sibling classes, each with extends + super() + super.x ---
function test_sibling_classes() {
    class Base {
        constructor() { this.base = true; }
        baseVal() { return 100; }
        static staticBase() { return 200; }
    }
    class A extends Base {
        constructor(x) {
            super();
            this.a = x;
        }
        aVal() { return super.baseVal() + 1; }
        static aStatic() { return super.staticBase() + 10; }
    }
    class B extends Base {
        constructor(y) {
            super();
            this.b = y;
        }
        bVal() { return super.baseVal() + 2; }
        static bStatic() { return super.staticBase() + 20; }
    }
    var a = new A(1);
    var b = new B(2);
    assert(a.base === true, 'sibling A: super() sets base');
    assert(b.base === true, 'sibling B: super() sets base');
    assert(a.a === 1, 'sibling A: own field');
    assert(b.b === 2, 'sibling B: own field');
    assert(a.aVal() === 101, 'sibling A: super.baseVal()');
    assert(b.bVal() === 102, 'sibling B: super.baseVal()');
    assert(A.aStatic() === 210, 'sibling A: super.staticBase()');
    assert(B.bStatic() === 220, 'sibling B: super.staticBase()');
}

// --- 2. Deep inheritance chain ---
function test_deep_chain() {
    class L0 {
        constructor(v) { this.v = v; }
        depth() { return 0; }
    }
    class L1 extends L0 {
        constructor(v) {
            super(v);
            this.d1 = true;
        }
        depth() { return super.depth() + 1; }
    }
    class L2 extends L1 {
        constructor(v) {
            super(v);
            this.d2 = true;
        }
        depth() { return super.depth() + 1; }
    }
    class L3 extends L2 {
        constructor(v) {
            super(v);
            this.d3 = true;
        }
        depth() { return super.depth() + 1; }
    }
    var obj = new L3(99);
    assert(obj.v === 99, 'deep chain: value propagated');
    assert(obj.d1 === true, 'deep chain: L1 field');
    assert(obj.d2 === true, 'deep chain: L2 field');
    assert(obj.d3 === true, 'deep chain: L3 field');
    assert(obj.depth() === 3, 'deep chain: super.depth() recursive');
}

// --- 3. Object literal method with super AFTER class definitions ---
function test_obj_literal_after_class() {
    class MyClass {
        constructor(v) { this.v = v; }
        toString() { return 'MyClass:' + this.v; }
    }
    var proto = {
        greet() {
            return super.toString();
        }
    };
    var obj = Object.create(proto);
    assert(obj.greet() === '[object Object]', 'obj literal super.toString() falls back to Object.prototype');
}

// --- 4. Nested classes in one expression ---
function test_nested_classes() {
    class Outer {
        constructor(v) { this.outer = v; }
        outerVal() { return 42; }
    }
    var Inner;
    var obj = new (Inner = class extends Outer {
        constructor(v) {
            super(v);
            this.inner = v * 2;
        }
        innerVal() { return super.outerVal() + 8; }
    })(10);
    assert(obj.outer === 10, 'nested: outer field');
    assert(obj.inner === 20, 'nested: inner field');
    assert(obj.innerVal() === 50, 'nested: super.outerVal()');
}

// --- 5. Static super on both sibling classes ---
function test_static_super_siblings() {
    class P {
        static baseStatic = 42;
    }
    class S1 extends P {
        static getStatic() { return super.baseStatic; }
    }
    class S2 extends P {
        static getStatic() { return super.baseStatic + 100; }
    }
    assert(S1.getStatic() === 42, 'static super S1');
    assert(S2.getStatic() === 142, 'static super S2');
}

// --- 6. Classes without extends must not break ---
function test_no_extends() {
    class A {
        constructor() { this.x = 1; }
    }
    class B {
        constructor() { this.y = 2; }
    }
    var a = new A();
    var b = new B();
    assert(a.x === 1, 'no extends A');
    assert(b.y === 2, 'no extends B');
}

// --- 7. Class extending built-in ---
function test_extends_builtin() {
    class MyArray extends Array {
        last() { return super.at(-1); }
    }
    var arr = new MyArray(1, 2, 3);
    assert(arr.last() === 3, 'extends Array: last()');
    assert(arr instanceof Array, 'extends Array: instanceof');
}

// --- 8. Mixed extends and no-extends siblings ---
function test_mixed() {
    class Base {
        constructor() { this.b = 10; }
        getB() { return this.b; }
    }
    class With extends Base {
        constructor() {
            super();
            this.w = 20;
        }
    }
    class Without {
        constructor() { this.wo = 30; }
    }
    var w = new With();
    var wo = new Without();
    assert(w.getB() === 10, 'mixed: With.getB()');
    assert(w.w === 20, 'mixed: With own field');
    assert(wo.wo === 30, 'mixed: Without own field');
}

// Run all tests
test_sibling_classes();
test_deep_chain();
test_obj_literal_after_class();
test_nested_classes();
test_static_super_siblings();
test_no_extends();
test_extends_builtin();
test_mixed();

print(pass + '/' + (pass + fail) + ' tests passed');
if (fail > 0) {
    throw new Error(fail + ' test(s) failed');
}
