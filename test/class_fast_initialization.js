function check(value, message) {
    if (!value) throw new Error(message);
}
function throws(fn, type, message) {
    let caught = false;
    try { fn(); } catch (e) { caught = e instanceof type; }
    check(caught, message);
}
class Record {
    constructor(x, y, z) { this.x = x; this.y = y; this.z = z; }
}
function make(x, y, z) { return new Record(x, y, z); }
for (let i = 0; i < 500; i++) {
    const p = make(i, i + 1, i + 2);
    check(p.x === i && p.y === i + 1 && p.z === i + 2, 'parameter stores');
}
let order = [];
Object.defineProperty(Record.prototype, 'y', {
    configurable: true,
    set(value) {
        order.push(Object.keys(this).join(','));
        check(this.x === 1 && this.z === undefined, 'setter observes assignment order');
        this.saved = value;
    }
});
let p = make(1, 2, 3);
check(order.join() === 'x' && p.saved === 2 && p.z === 3, 'warmed setter guard');
check(!Object.prototype.hasOwnProperty.call(p, 'y'), 'setter owns no y');
delete Record.prototype.y;
for (let i = 0; i < 20; i++) make(i, i, i);
Object.defineProperty(Record.prototype, 'z', { value: 9, configurable: true });
throws(() => make(1, 2, 3), TypeError, 'strict inherited readonly property');
delete Record.prototype.z;
for (let i = 0; i < 20; i++) make(i, i, i);
p = make();
check(Object.keys(p).join(',') === 'x,y,z' && p.x === undefined && p.z === undefined,
      'missing parameters become own undefined properties');
for (let i = 0; i < 500; i++) {
    const text = ['field', i, 'suffix'].join('-');
    const value = { i: i };
    p = make(text, value, text);
    check(p.x === text && p.y === value && p.z === text, 'heap value ownership');
}
function Plain(x, y) { this.x = x; this.y = y; }
function plain(x, y) { return new Plain(x, y); }
for (let i = 0; i < 30; i++) plain(i, i);
Plain.prototype = { tag: 7 };
p = plain(1, 2);
check(Object.getPrototypeOf(p) === Plain.prototype && p.tag === 7, 'prototype reassignment');
Object.defineProperty(Plain.prototype, 'y', { value: 8, configurable: true });
p = plain(1, 2);
check(p.x === 1 && p.y === 8 && !Object.prototype.hasOwnProperty.call(p, 'y'),
      'sloppy readonly write');
Plain.prototype = 0;
p = plain(4, 5);
check(Object.getPrototypeOf(p) === Object.prototype && p.y === 5, 'default intrinsic prototype');
function Four(a, b, c, d) { this.a = a; this.b = b; this.c = c; this.d = d; }
for (let i = 0; i < 50; i++) {
    p = new Four(i, i + 1, i + 2, i + 3);
    check(p.d === i + 3 && Object.keys(p).join(',') === 'a,b,c,d', 'inline capacity');
}
function Duplicate(a, b) { this.x = a; this.x = b; }
for (let i = 0; i < 50; i++) check(new Duplicate(i, i + 1).x === i + 1, 'duplicate stores');
function replacement(a) { this.x = a; return { y: a }; }
for (let i = 0; i < 30; i++) check(new replacement(i).y === i, 'explicit object return');
class Fields {
    value = 6;
    #secret = 9;
    constructor(x) { this.x = x; }
    read() { return this.#secret; }
}
for (let i = 0; i < 30; i++) {
    p = new Fields(i);
    check(p.value === 6 && p.read() === 9 && p.x === i, 'instance elements');
}
class Derived extends Record {
    value = 11;
    constructor(x, y, z) { super(x, y, z); this.extra = 12; }
}
function derived(x, y, z) { return new Derived(x, y, z); }
for (let i = 0; i < 200; i++) {
    p = derived(i, i + 1, i + 2);
    check(p.z === i + 2 && p.value === 11 && p.extra === 12 && p instanceof Derived,
          'super binds this and initializes derived fields');
}
Object.defineProperty(Derived.prototype, 'y', {
    configurable: true, set(value) { this.derivedY = value; }
});
p = derived(1, 2, 3);
check(p.derivedY === 2 && !Object.prototype.hasOwnProperty.call(p, 'y'), 'new target prototype');
delete Derived.prototype.y;
Plain.prototype = {};
class Repeat extends Plain {
    constructor(x, y) {
        super(x, y);
        try { super(x + 1, y + 1); } catch (e) { check(e instanceof ReferenceError, 'repeat super'); return; }
        throw new Error('repeat super succeeded');
    }
}
for (let i = 0; i < 30; i++) check(new Repeat(1, 2).x === 1, 'repeat leaves binding intact');
class BuiltinDerived extends Array {
    constructor() { super(1, 2); this.extra = 3; }
}
for (let i = 0; i < 20; i++) {
    p = new BuiltinDerived();
    check(p.length === 2 && p[1] === 2 && p.extra === 3, 'builtin super binding');
}
print('PASS class fast initialization');
