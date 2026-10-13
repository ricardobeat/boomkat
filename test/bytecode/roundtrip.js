function check(value, message) { if (!value) throw new Error(message); }
check(this === undefined, 'module top-level this');
check((function () { return this; })() === undefined, 'strict function this');
var moduleLocal = 42;
function moduleFunction() { return moduleLocal; }
check(!Object.prototype.hasOwnProperty.call(globalThis, 'moduleLocal'), 'module var scope');
check(!Object.prototype.hasOwnProperty.call(globalThis, 'moduleFunction'), 'module function scope');
function counter(initial) { return () => ++initial; }
var next = counter(40);
check(next() === 41 && next() === 42, 'captured cells');
function defaults(a = 4, ...rest) { return a + rest.reduce((x, y) => x + y, 0); }
check(defaults(undefined, 10, 28) === 42, 'defaults and rest');
class Base { constructor(v) { this.value = v; } get doubled() { return this.value * 2; } }
class Child extends Base {
    #offset = 1;
    constructor(v) { super(v); }
    answer() { return super.doubled + this.#offset; }
}
check(new Child(20).answer() === 41, 'class field initializers and super');
function destruct({a, b = 2}, [c, ...tail]) { return a + b + c + tail[0]; }
check(destruct({a: 10}, [20, 10]) === 42, 'destructuring');
check(JSON.parse(JSON.stringify({answer: 42})).answer === 42, 'JSON');
function* sequence() { yield 1; yield 2; }
check(Array.from(sequence()).join(',') === '1,2', 'generator state');
function retained(x) { return x + 1; }
check(retained.toString().indexOf('return x + 1') >= 0, 'retained source');
var unicode = 'a\u0000\uD800é';
check(unicode.length === 4 && unicode.charCodeAt(2) === 0xD800, 'CESU-8 constants');
var numbers = [-0, NaN, Infinity, -123.5, 1234567890123];
check(Object.is(numbers[0], -0) && Number.isNaN(numbers[1]) && numbers[2] === Infinity && numbers[4] === 1234567890123, 'numeric constants');
var site;
function tag(strings) { if (site) check(site === strings, 'template site cache'); site = strings; return strings.raw[0]; }
function template() { return tag`hello\n`; }
check(template() === 'hello\\n' && template() === 'hello\\n', 'tagged template');
export const exported = moduleFunction();
check(exported === 42, 'local export');
check(new Date(0).toISOString() === '1970-01-01T00:00:00.000Z', 'Date');
check('é'.toUpperCase() === 'É', 'Unicode case conversion');
for (var name of ['console', 'Temporal', 'Intl', 'BigInt', 'WeakRef', 'FinalizationRegistry',
                  'Atomics', 'SharedArrayBuffer', 'RegExp', 'ArrayBuffer', 'DataView',
                  'Uint8Array', 'Map', 'Set', 'WeakMap', 'WeakSet', 'Proxy']) {
    check(!Object.prototype.hasOwnProperty.call(globalThis, name), name + ' excluded');
}
check(typeof String.prototype.normalize === 'undefined', 'normalize excluded');
print('bytecode roundtrip passed');
