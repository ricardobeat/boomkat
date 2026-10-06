function same(actual, expected) {
    if (actual !== expected) throw new Error(actual + ' != ' + expected);
}
function plain(x) { const [a, b] = [x, x + 1]; return a + b; }
same(plain(4), 9);
const log = [];
function effect(x) { log.push(x); return x; }
const [first] = [effect(1), effect(2), effect(3)];
same(first, 1); same(log.join(','), '1,2,3');
const [anonymous, another] = [function () {}, () => 1];
same(anonymous.name, ''); same(another.name, '');
let tdz = false;
try { const [a, b] = [1, a]; }
catch (e) { tdz = e instanceof ReferenceError; }
same(tdz, true);

const original = Array.prototype[Symbol.iterator];
const iteratorProto = Object.getPrototypeOf([][Symbol.iterator]());
const next = iteratorProto.next;
let receiver;
function patch() {
    Array.prototype[Symbol.iterator] = function () {
        receiver = this;
        return original.call(this);
    };
    return 2;
}
try {
    const [a, b] = [1, patch()];
    same(a, 1); same(b, 2);
    same(receiver.length, 2); same(receiver[1], 2);
} finally { Array.prototype[Symbol.iterator] = original; }

let calls = 0;
try {
    iteratorProto.next = function () { calls++; return next.call(this); };
    same(plain(5), 11);
    same(calls, 2);
} finally { iteratorProto.next = next; }
calls = 0;
try {
    iteratorProto.return = function () { calls++; return {}; };
    same(plain(6), 13);
    same(calls, 1);
} finally { delete iteratorProto.return; }

const seen = [];
try {
    Array.prototype[Symbol.iterator] = function () {
        seen.push(this);
        let i = 0;
        return {next() { return {value: ++i * 10, done: false}; }};
    };
    same(plain(1), 30); same(plain(1), 30);
    same(seen.length, 2); same(seen[0] === seen[1], false);
    same(seen[0][0], 1); same(seen[0][1], 2);
} finally { Array.prototype[Symbol.iterator] = original; }

function values(i) {
    const [text, object, missing] = ['text-' + i, {i}, undefined];
    for (var j = 0; j < 12; j++) ({garbage: [j, 'garbage-' + j]});
    same(missing, undefined);
    return [text, object];
}
for (var i = 0; i < 200; i++) {
    const result = values(i);
    same(result[0], 'text-' + i); same(result[1].i, i);
}
const [withDefault = 7] = [undefined];
same(withDefault, 7);
const [prefix, ...rest] = [1, 2, 3];
same(prefix, 1); same(rest.join(','), '2,3');
const [hole] = [,];
same(hole, undefined);
const [spread] = [...[8]];
same(spread, 8);
