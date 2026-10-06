function same(actual, expected, name) {
    if (!Object.is(actual, expected)) throw new Error(name + ': ' + actual + ' != ' + expected);
}

function readLoop(o, n) {
    let sum = 0;
    for (let i = 0; i < n; i++) sum += o.x + o.y;
    return sum;
}
const proto = {x: 3, y: 4};
const object = Object.create(proto);
same(readLoop(object, 20000), 140000, 'inherited region');
proto.x = 10;
same(readLoop(object, 20000), 280000, 'changed data value');
object.x = 1;
same(readLoop(object, 20000), 100000, 'shadow');
delete object.x;
Object.setPrototypeOf(object, {x: 2, y: 6});
same(readLoop(object, 20000), 160000, 'new prototype');
for (let i = 0; i < 100; i++) object['p' + i] = i;
same(readLoop(object, 20000), 160000, 'storage growth');

let getterReads = 0;
const getterObject = {x: 1, get y() { getterReads++; this.x++; return 2; }};
same(readLoop(getterObject, 100), 5250, 'getter mutates earlier read');
same(getterReads, 100, 'getter count');
let conversions = 0;
const coercing = {x: {valueOf() { conversions++; return 5; }}, y: 3};
same(readLoop(coercing, 100), 800, 'coercion');
same(conversions, 100, 'conversion count');
let traps = 0;
const proxy = new Proxy({x: 2, y: 3}, {get(o, k) { traps++; return o[k]; }});
same(readLoop(proxy, 100), 500, 'proxy');
same(traps, 200, 'proxy count');

function mutateLoop(o, n) {
    let sum = 0;
    for (let i = 0; i < n; i++) { sum += o.x; o.x++; sum += o.x; }
    return sum;
}
same(mutateLoop({x: 0}, 100), 10000, 'write barrier');
function callLoop(o, f, n) {
    let sum = 0;
    for (let i = 0; i < n; i++) { sum += o.x; f(o); sum += o.x; }
    return sum;
}
same(callLoop({x: 0}, o => o.x++, 100), 10000, 'call barrier');

class Point {
    constructor(x, y) { this.x = x; this.y = y; }
    get magnitude() { return this.x * this.x + this.y * this.y; }
    translate(dx, dy) { this.x += dx; this.y += dy; return this; }
    twice(dx) { this.x += dx; this.x += dx; return this.x; }
}
const point = new Point(3, 4);
for (let i = 0; i < 1000; i++) same(point.magnitude, 25, 'numeric getter');
for (let i = 0; i < 1000; i++) same(point.translate(1, 1), point, 'method receiver');
same(point.x, 1003, 'method writes x');
same(point.y, 1004, 'method writes y');
same(point.twice(2), 1007, 'staged read after write');

let observed;
point.y = {valueOf() { observed = point.x; return 10; }};
point.translate(1, 2);
same(observed, 1008, 'fallback sees first write');
same(point.y, 12, 'fallback second write');
Object.defineProperty(point, 'y', {get() { return 2; }, set(v) { observed = this.x; }, configurable: true});
point.translate(1, 1);
same(observed, 1009, 'setter fallback order');
Object.defineProperty(point, 'y', {get() { throw new Error('expected'); }, configurable: true});
try { point.translate(1, 1); } catch (e) { same(e.message, 'expected', 'throw'); }
same(point.x, 1010, 'write survives abrupt completion');

function numeric(a, b, c) { return (a + b) * c - a; }
for (let i = 0; i < 1000; i++) same(numeric(2, 3, 4), 18, 'numeric body');
same(numeric('2', 3, 4), 90, 'string fallback');
same(numeric(2n, 3n, 4n), 18n, 'BigInt fallback');
same(numeric(Infinity, 1, 0), NaN, 'NaN');
function product(a, b) { return a * b; }
for (let i = 0; i < 1000; i++) product(2, 3);
same(product(-0, 2), -0, 'negative zero');
same(product(140737488355327, 140737488355327), 140737488355327 * 140737488355327, 'large product');
function associated(a, b, c) { return (a + b) + c; }
for (let i = 0; i < 1000; i++) associated(1, 2, 3);
same(associated(1e20, -1e20, 1), 1, 'association');

function strictThis() { 'use strict'; return this; }
for (let i = 0; i < 1000; i++) same(strictThis(), undefined, 'strict receiver');
function makeCapture() {
    let value = 0;
    const peek = () => value;
    for (let i = 0; i < 1000; i++) { value = i; same(peek(), i, 'mutable capture'); }
    value = 'heap string';
    same(peek(), value, 'captured string');
    value = {x: 1};
    same(peek(), value, 'captured object');
}
makeCapture();
let callee = numeric;
function dynamic(a, b, c) { return callee(a, b, c) + 1; }
for (let i = 0; i < 1000; i++) same(dynamic(2, 3, 4), 19, 'dynamic warm call');
callee = () => 99;
same(dynamic(2, 3, 4), 100, 'reassigned callee');
print('PASS hot regions');
