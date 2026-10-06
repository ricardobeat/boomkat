function equal(actual, expected) {
    if (!Object.is(actual, expected)) throw new Error(actual + ' != ' + expected);
}
class Pair {
    constructor(x, y) { this.x = x; this.y = y; }
    get value() { return this.x * this.x + this.y; }
}
function read(x, y) { return new Pair(x, y).value; }
for (let i = 0; i < 100; i++) equal(read(i, 2), i * i + 2);
equal(read(-0, -0), 0);
equal(read(NaN, 1), NaN);
equal(read(2, undefined), NaN);
equal(read(2, 'a'), '4a');
equal(read(2n, 1n), 5n);
let conversions = 0;
equal(read({ valueOf() { conversions++; return 3; } }, 1), 10);
equal(conversions, 2);
let order = '';
function argument(value, label) { order += label; return value; }
equal(new Pair(argument(3, 'x'), argument(4, 'y')).value, 13);
equal(order, 'xy');

let original = Object.getOwnPropertyDescriptor(Pair.prototype, 'value');
Object.defineProperty(Pair.prototype, 'value', { configurable: true, get() { return this.x + this.y; } });
equal(read(3, 4), 7);
Object.defineProperty(Pair.prototype, 'value', original);
equal(read(3, 4), 13);
Object.defineProperty(Pair.prototype, 'value', { configurable: true, value: 99 });
equal(read(3, 4), 99);
Object.defineProperty(Pair.prototype, 'value', original);
let setters = 0;
Object.defineProperty(Pair.prototype, 'x', { configurable: true, set(value) { setters++; this.saved = value; }, get() { return this.saved + 1; } });
equal(read(3, 4), 20);
equal(setters, 1);
delete Pair.prototype.x;
for (let i = 0; i < 10; i++) equal(read(3, 4), 13);
let oldParent = Object.getPrototypeOf(Pair.prototype);
Object.setPrototypeOf(Pair.prototype, { set y(value) { this.savedY = value; }, get y() { return this.savedY + 2; } });
equal(read(3, 4), 15);
Object.setPrototypeOf(Pair.prototype, oldParent);
equal(read(3, 4), 13);
let SavedPair = Pair;
Pair = class { constructor(x, y) { this.value = x - y; } };
equal(read(3, 4), -1);
Pair = SavedPair;
equal(read(3, 4), 13);
// Argument evaluation may replace a getter or constructor binding.
function replaceGetter() {
    Object.defineProperty(Pair.prototype, 'value', { configurable: true, value: 17 });
    return 1;
}
equal(read(replaceGetter(), 2), 17);
Object.defineProperty(Pair.prototype, 'value', original);
function replaceClass() { Pair = class { constructor() { this.value = 42; } }; return 1; }
equal(new Pair(replaceClass(), 2).value, 3);
equal(read(1, 2), 42);
Pair = SavedPair;

class Shadow {
    constructor(value) { this.value = value; }
    get value() { return this.value * 2; }
}
let threw = false;
try { new Shadow(3).value; } catch (e) { threw = e instanceof TypeError; }
equal(threw, true);
class ReturnField {
    constructor(x) { this.x = x; }
    get value() { return this.x; }
}
for (let i = 0; i < 100; i++) equal(new ReturnField(i).value, i);
class Swapped {
    constructor(x, y) { this.y = x; this.x = y; }
    get value() { return this.x / this.y - 1; }
}
for (let i = 1; i < 100; i++) equal(new Swapped(i, i * 2).value, 1);
class HasField {
    extra = 3;
    constructor(x) { this.x = x; }
    get value() { return this.x * this.extra; }
}
equal(new HasField(2).value, 6);
print('PASS scalar class initialization');
