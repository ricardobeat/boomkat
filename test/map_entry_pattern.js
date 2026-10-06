function same(actual, expected) {
    if (actual !== expected) throw new Error(actual + ' != ' + expected);
}
function collect(map) {
    const result = [];
    for (const [key, value] of map) result.push(key, value);
    return result;
}
const key = {}, value = {}, symbol = Symbol('entry');
const map = new Map([[key, value], [undefined, symbol], ['s', undefined]]);
const result = collect(map);
same(result[0], key); same(result[1], value);
same(result[2], undefined); same(result[3], symbol);
same(result[4], 's'); same(result[5], undefined);
same(collect(new Map()).length, 0);
same(collect(new Map([['ab', 2]]).keys()).join(','), 'a,b');
same(collect(new Map([[1, [4, 5]]]).values()).join(','), '4,5');

function mutate() {
    const m = new Map([[0, 1], [1, 2], [2, 3]]);
    let sum = 0;
    for (const [k, v] of m) {
        sum += k + v;
        if (k === 0) { m.delete(1); m.set(3, 4); }
    }
    return sum;
}
same(mutate(), 13);

const mapProto = Object.getPrototypeOf(new Map().entries());
const arrayProto = Object.getPrototypeOf([][Symbol.iterator]());
const next = mapProto.next;
let calls = 0;
try {
    mapProto.next = function () { calls++; return next.call(this); };
    same(collect(new Map([[1, 2]])).join(','), '1,2');
    same(calls, 2);
} finally { mapProto.next = next; }

const arrayNext = arrayProto.next;
calls = 0;
const one = new Map([[1, 2]]);
try {
    arrayProto.next = function () { calls++; return arrayNext.call(this); };
    same(collect(one).join(','), '1,2');
    same(calls, 2);
} finally { arrayProto.next = arrayNext; }

const arrayIterator = Array.prototype[Symbol.iterator];
calls = 0;
try {
    Array.prototype[Symbol.iterator] = function () {
        calls++;
        return arrayIterator.call(this);
    };
    same(collect(one).join(','), '1,2');
    same(calls, 1);
} finally { Array.prototype[Symbol.iterator] = arrayIterator; }

calls = 0;
try {
    arrayProto.return = function () { calls++; return {}; };
    same(collect(one).join(','), '1,2');
    same(calls, 1);
} finally { delete arrayProto.return; }

const two = new Map([[1, 2], [3, 4]]);
calls = 0;
try {
    for (const [k, v] of two) {
        if (k === 1) arrayProto.return = function () { calls++; return {}; };
        if (k === 3) same(v, 4);
    }
    same(calls, 1);
} finally { delete arrayProto.return; }

function continued(m) {
    let sum = 0;
    for (const [k, v] of m) {
        if (k === 1) continue;
        sum += v;
    }
    return sum;
}
same(continued(two), 4);

function abrupt(m, kind) {
    for (const [k, v] of m) {
        if (kind === 0) break;
        if (kind === 1) return k + v;
        throw value;
    }
}
calls = 0;
try {
    mapProto.return = function () { calls++; return {}; };
    abrupt(one, 0);
    same(abrupt(one, 1), 3);
    try { abrupt(one, 2); } catch (e) { same(e, value); }
    same(calls, 3);
} finally { delete mapProto.return; }

function capture(m) {
    const functions = [];
    for (let [k, v] of m) functions.push(() => k + v);
    return functions;
}
same(capture(new Map([[1, 2], [3, 4]])).map(f => f()).join(','), '3,7');
for (let i = 0; i < 300; i++) {
    const text = 'value-' + i;
    const r = collect(new Map([[text, {text}]]));
    same(r[0], text); same(r[1].text, text);
}
