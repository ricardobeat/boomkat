function check(value, message) {
    if (!value) throw new Error(message);
}

const excluded = [
    [Array, ['fromAsync']],
    [Array.prototype, ['flat', 'flatMap', 'findLast', 'findLastIndex',
        'toReversed', 'toSorted', 'toSpliced', 'with', 'at']],
    [Promise, ['any', 'allSettled', 'withResolvers', 'try']],
    [Object, ['groupBy', 'fromEntries', 'getOwnPropertyDescriptors', 'hasOwn']],
    [String.prototype, ['replaceAll', 'matchAll', 'isWellFormed', 'toWellFormed',
        'padStart', 'padEnd', 'at']],
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
