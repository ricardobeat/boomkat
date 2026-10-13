// Opcodes that run user code inline (getters during object rest, a generator's
// return() during iterator close, a delegate's methods during yield*) can grow
// and move the value stack. Registers written afterwards must land in the
// live frame.
function equal(actual, expected) {
    if (actual !== expected) throw new Error(actual + ' !== ' + expected);
}

async function objectRest() {
    var seen = [];
    for await (var {...x} of [{ get v() { return 2; } }]) seen.push('in', x.v);
    equal(seen.join(), 'in,2');
}

async function iteratorClose() {
    var first = 0;
    function* g() { first++; yield; }
    var seen = [];
    for await (var [,] of [g()]) seen.push('in', first);
    equal(seen.join(), 'in,1');
}

async function asyncClose() {
    var closed = 0;
    var iterable = {
        [Symbol.asyncIterator]() {
            return {
                next() { return Promise.resolve({ value: 1, done: false }); },
                return() { closed++; return Promise.resolve({ done: true }); }
            };
        }
    };
    var seen = [];
    for await (var v of iterable) { seen.push('in', v); break; }
    equal(seen.join() + ',' + closed, 'in,1,1');
}

function* delegate() {
    var inner = { [Symbol.iterator]() { return this; },
        next() { return { get done() { return true; }, get value() { return 'v'; } }; } };
    var result = yield* inner;
    equal(result, 'v');
    return 'after';
}
equal(delegate().next().value, 'after');

objectRest().then(iteratorClose).then(asyncClose);
