// A store that adds a property must respect the prototype chain, the
// extensibility of the receiver and the shape of every link.

var pass = 0;
var fail = 0;

function eq(actual, expected, msg) {
    if (actual === expected) { pass++; }
    else { fail++; print('FAIL: ' + msg + ' (got ' + actual + ', want ' + expected + ')'); }
}
function ok(value, msg) { eq(value ? 1 : 0, 1, msg); }

class Point {
    constructor(x, y) {
        this.x = x;
        this.y = y;
    }
    sum() { return this.x + this.y; }
}

let p = new Point(1, 2);
eq(p.x, 1, 'x');
eq(p.y, 2, 'y');
eq(p.sum(), 3, 'sum');
eq(Object.keys(p).length, 2, 'keys');

// A second class with the same shape but another prototype.
class Other {
    constructor(x, y) {
        this.x = x;
        this.y = y;
    }
}
let o = new Other(3, 4);
eq(o.x, 3, 'other x');
eq(o.y, 4, 'other y');
eq(Object.keys(o).length, 2, 'other keys');

// A setter on the prototype must intercept the store.
let seen = [];
class WithSetter {
    constructor() {
        this.v = 1;
    }
}
Object.defineProperty(WithSetter.prototype, 'v', {
    set(value) { seen.push(value); },
    configurable: true,
});
let w = new WithSetter();
eq(seen.length, 1, 'setter ran');
eq(seen[0], 1, 'setter value');
ok(!Object.prototype.hasOwnProperty.call(w, 'v'), 'no own property');

// A non-extensible receiver drops the store in sloppy code.
let frozen = Object.preventExtensions({ a: 1 });
frozen.b = 2;
ok(!Object.prototype.hasOwnProperty.call(frozen, 'b'), 'no new property');

// A store of an object value keeps the value alive.
class Holder { constructor() { this.payload = { n: 5 }; } }
for (let i = 0; i < 1000; i++) {
    let h = new Holder();
    eq(h.payload.n, 5, 'payload');
}

// A store of a string value keeps the reference count right.
class Text { constructor() { this.name = 'boomkat'; } }
for (let i = 0; i < 1000; i++) {
    let t = new Text();
    eq(t.name, 'boomkat', 'name');
}

// A store that follows a prototype change must not append.
class Base { constructor() { this.q = 1; } }
class Derived extends Base { constructor() { super(); this.q = 2; } }
let d = new Derived();
eq(d.q, 2, 'derived');

print(pass + ' passed, ' + fail + ' failed');
