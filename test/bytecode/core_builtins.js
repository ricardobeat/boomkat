function check(value, message) {
    if (!value) throw new Error(message);
}

const excluded = [
    [Array, ['fromAsync']],
    [Array.prototype, ['flat', 'flatMap', 'findLast', 'findLastIndex',
        'toReversed', 'toSorted', 'toSpliced', 'with', 'at']],
    [Promise, ['any', 'allSettled', 'withResolvers', 'try']],
    [Object, ['groupBy', 'fromEntries', 'getOwnPropertyDescriptors', 'hasOwn']],
    [Object.prototype, ['toLocaleString', '__proto__', '__defineGetter__',
        '__defineSetter__', '__lookupGetter__', '__lookupSetter__']],
    [Number.prototype, ['toLocaleString']],
    [Array.prototype, ['toLocaleString']],
    [Date.prototype, ['toLocaleString', 'toLocaleDateString', 'toLocaleTimeString',
        'getYear', 'setYear', 'toGMTString']],
    [String.prototype, ['replaceAll', 'matchAll', 'isWellFormed', 'toWellFormed',
        'padStart', 'padEnd', 'at', 'localeCompare', 'toLocaleLowerCase',
        'toLocaleUpperCase', 'substr', 'trimLeft', 'trimRight']],
    [Math, ['sumPrecise']],
    [Error, ['isError']],
    [JSON, ['rawJSON', 'isRawJSON']],
];
for (const [object, names] of excluded) {
    for (const name of names) {
        check(!Object.prototype.hasOwnProperty.call(object, name), name + ' registered');
        check(object[name] === undefined, name + ' accessible');
    }
}
check(typeof Reflect === 'undefined' && !('Reflect' in globalThis), 'Reflect global');
check(typeof escape === 'undefined' && !('escape' in globalThis), 'escape global');
check(typeof unescape === 'undefined' && !('unescape' in globalThis), 'unescape global');

// Removing prototype helpers leaves ordinary prototype and accessor semantics intact.
const parent = { value: 7 };
const child = { __proto__: parent };
check(Object.getPrototypeOf(child) === parent && child.value === 7, 'prototype literal');
Object.setPrototypeOf(child, null);
check(Object.getPrototypeOf(child) === null && child.value === undefined, 'setPrototypeOf');
const object = Object.create(parent);
Object.defineProperty(object, 'answer', { get() { return this.value * 6; }, enumerable: true });
check(object.answer === 42 && Object.keys(object).join(',') === 'answer', 'accessor');
check(typeof Object.getOwnPropertyDescriptor(object, 'answer').get === 'function', 'descriptor');
check(' ab '.trimStart().trimEnd() === 'ab' && 'abcd'.slice(1, 3) === 'bc', 'string alternatives');
check('Ab'.toUpperCase() === 'AB' && (1234).toString() === '1234', 'ordinary conversions');
check(decodeURIComponent(encodeURIComponent('a b/é')) === 'a b/é', 'URI helpers retained');
check((1.25).toFixed(1) === '1.3', 'numeric formatting retained');
check(new Date(0).toISOString() === '1970-01-01T00:00:00.000Z', 'ISO date formatting');
check(new Date(0).toUTCString() === 'Thu, 01 Jan 1970 00:00:00 GMT', 'UTC date formatting');

const results = await Promise.all([Promise.resolve(3), (async () => 4)()]);
check(results.join(',') === '3,4', 'Promise.all and async');
check(await Promise.race([Promise.resolve(7)]) === 7, 'Promise.race');
let cleaned = false;
await Promise.resolve().finally(() => { cleaned = true; });
check(cleaned, 'Promise.finally');

function* values() { yield 2; yield* [3, 4]; }
let sum = 0;
for (const value of values()) sum += value;
check(sum === 9, 'generators and for-of');
class Counter { #value = 8; get() { return this.#value; } }
check(new Counter().get() === 8, 'private fields');
check(new Date(Date.UTC(2001, 0, 2)).getUTCFullYear() === 2001, 'Date');
check(JSON.stringify(JSON.parse('{"x":3}', (key, value) => key === 'x' ? value + 1 : value))
    === '{"x":4}', 'JSON reviver and stringify');
check([1, 2, 3].map(x => x * 2).join(',') === '2,4,6', 'Array.map');
check('Ab'.toLowerCase() === 'ab', 'String case conversion');
print('core builtins passed');
