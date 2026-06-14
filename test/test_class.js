// ES6 Class tests

var pass = 0;
var fail = 0;

function assert(cond, msg) {
    if (cond) { pass++; } else { fail++; print('FAIL: ' + msg); }
}

// Test 1: basic class declaration
class Point {
    constructor(x, y) {
        this.x = x;
        this.y = y;
    }
}
var pt = new Point(3, 4);
assert(pt.x === 3, 'class Point constructor sets x');
assert(pt.y === 4, 'class Point constructor sets y');
assert(pt instanceof Point, 'pt instanceof Point');

// Test 2: class with method
class Greeter {
    constructor(name) {
        this.name = name;
    }
    greet() {
        return 'Hello, ' + this.name;
    }
}
var g = new Greeter('World');
assert(g.greet() === 'Hello, World', 'class method');

// Test 3: class expression
var ExprClass = class {
    constructor(v) {
        this.v = v;
    }
    get() {
        return this.v;
    }
};
var ec = new ExprClass(42);
assert(ec.get() === 42, 'class expression');

// Test 4: anonymous class expression
var anon = new (class { constructor() { this.tag = 'anon'; } })();
assert(anon.tag === 'anon', 'anonymous class expression');

// Test 5: static method
class MathUtil {
    static add(a, b) {
        return a + b;
    }
}
assert(MathUtil.add(1, 2) === 3, 'static method');

// Test 6: typeof class
assert(typeof Point === 'function', 'typeof class is function');

// Test 7: no prototype chain (TinyDuck: flat class tables, no .prototype lookup)
assert(Point.prototype === undefined, 'class has no prototype');
assert(Greeter.prototype === undefined, 'class has no prototype');

// Test 8: default constructor
class Empty {}
var e = new Empty();
assert(e !== undefined, 'default constructor creates instance');
assert(e instanceof Empty, 'default constructor instanceof');

// Test 9: multiple instances
class Counter {
    constructor() {
        this.count = 0;
    }
    inc() {
        this.count = this.count + 1;
        return this.count;
    }
}
var c1 = new Counter();
var c2 = new Counter();
assert(c1.inc() === 1, 'counter 1 first inc');
assert(c1.inc() === 2, 'counter 1 second inc');
assert(c2.inc() === 1, 'counter 2 first inc');

// Test 10: class with extends (super calls walk the class table, not a proto chain)
class Animal {
    speak() {
        return 'animal';
    }
}
class Dog extends Animal {
    bark() {
        return 'woof';
    }
}
var dog = new Dog();
assert(dog.bark() === 'woof', 'derived class method');
assert(dog.speak() === 'animal', 'inherited method');
assert(dog instanceof Dog, 'dog instanceof Dog');
assert(dog instanceof Animal, 'dog instanceof Animal');

// Test 11: extends with constructor calling super
class Cat extends Animal {
    constructor(name) {
        super();
        this.name = name;
    }
    speak() {
        return this.name + ' says meow';
    }
}
var cat = new Cat('Whiskers');
assert(cat.speak() === 'Whiskers says meow', 'derived class with super()');
assert(cat instanceof Cat, 'cat instanceof Cat');
assert(cat instanceof Animal, 'cat instanceof Animal');

// Test 12: static method on derived class
class Base {
    static who() {
        return 'Base';
    }
}
class Child extends Base {
    static who() {
        return 'Child';
    }
}
assert(Base.who() === 'Base', 'base static method');
assert(Child.who() === 'Child', 'derived static method');

// Test 13: new.target in constructor
class TargetTest {
    constructor() {
        this.target = new.target;
    }
}
var tt = new TargetTest();
assert(tt.target === TargetTest, 'new.target is constructor function');

print('pass: ' + pass + ' fail: ' + fail);
