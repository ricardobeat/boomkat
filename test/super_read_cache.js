function check(value, message) { if (!value) throw new Error(message); }
const receiver = { x: 3 };
const base = { get value() { return this.x + 1; } };
const home = {
    __proto__: base,
    read() { return super.value; },
    computed(key) { return super[key]; }
};
for (let i = 0; i < 500; i++) check(home.read.call(receiver) === 4, 'getter receiver');
Object.defineProperty(base, 'value', { configurable: true, get() { return this.x + 2; } });
check(home.read.call(receiver) === 5, 'getter replacement');
Object.defineProperty(base, 'value', { configurable: true, value: 10, writable: true });
for (let i = 0; i < 30; i++) check(home.read.call(receiver) === 10, 'getter to data');
base.value = 11;
check(home.read.call(receiver) === 11, 'current data slot');
delete base.value;
check(home.read.call(receiver) === undefined, 'property deletion');
const parent = { get value() { return this.x + 3; } };
Object.setPrototypeOf(base, parent);
for (let i = 0; i < 100; i++) check(home.read.call(receiver) === 6, 'inherited getter');
base.value = 99;
Object.defineProperty(base, 'value', { configurable: true, value: 12 });
check(home.read.call(receiver) === 12, 'shadowing after warmup');
delete base.value;
Object.setPrototypeOf(home, { value: 13 });
check(home.read.call(receiver) === 13, 'home prototype reassignment');
Object.setPrototypeOf(home, base);
let coercions = 0;
const key = { toString() { coercions++; return 'value'; } };
for (let i = 0; i < 20; i++) check(home.computed.call(receiver, key) === 6, 'computed key');
check(coercions === 20, 'key conversion on every read');
const sym = Symbol('field');
parent[sym] = 14;
for (let i = 0; i < 30; i++) check(home.computed.call(receiver, sym) === 14, 'symbol key');
let seen;
const proxy = new Proxy({ value: 15 }, {
    get(target, key, r) { seen = r; return target[key]; }
});
Object.setPrototypeOf(base, proxy);
check(home.read.call(receiver) === 15 && seen === receiver, 'proxy in chain');
Object.setPrototypeOf(home, proxy);
check(home.read.call(receiver) === 15 && seen === receiver, 'proxy super base');
const sloppyBase = {};
Object.defineProperty(sloppyBase, 'value', { get: Function('return typeof this;') });
Object.setPrototypeOf(home, sloppyBase);
for (let i = 0; i < 30; i++) check(home.read.call(receiver) === 'object', 'sloppy warmup');
check(home.read.call(2) === 'object', 'sloppy getter boxes primitive receiver');
Object.defineProperty(sloppyBase, 'strictValue', {
    get: Function('"use strict"; return typeof this;')
});
for (let i = 0; i < 30; i++) check(home.computed.call(2, 'strictValue') === 'object',
    'sloppy method boxes receiver before strict getter');
class StrictHome {
    read() { return super.value; }
    computed(key) { return super[key]; }
}
Object.setPrototypeOf(StrictHome.prototype, sloppyBase);
for (let i = 0; i < 30; i++) check(StrictHome.prototype.read.call(receiver) === 'object', 'strict caller warmup');
check(StrictHome.prototype.read.call(2) === 'object', 'strict caller, sloppy getter boxing');
for (let i = 0; i < 30; i++) check(StrictHome.prototype.computed.call(2, 'strictValue') === 'number',
      'strict getter preserves primitive');
print('PASS super read cache');
