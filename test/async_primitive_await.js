function check(actual, expected) {
    if (actual !== expected) throw new Error('primitive await: ' + String(actual) + ' !== ' + String(expected));
}
async function identity(value) { return await value; }
async function verify() {
    var symbol = Symbol('await');
    var values = [undefined, null, true, false, 0, -0, NaN, Infinity, 123n, symbol, 'long'.repeat(300)];
    var getters = 0;
    var prototypes = [Number.prototype, String.prototype, Boolean.prototype, BigInt.prototype, Symbol.prototype];
    prototypes.forEach(function (p) {
        Object.defineProperty(p, 'then', { configurable: true, get: function () { getters++; throw new Error('primitive then'); } });
    });
    try {
        for (var i = 0; i < values.length; i++) check(Object.is(await identity(values[i]), values[i]), true);
        check(getters, 0);
        try { await Object(1); throw new Error('boxed await should reject'); }
        catch (e) { check(e.message, 'primitive then'); }
        check(getters, 1);
    } finally { prototypes.forEach(function (p) { delete p.then; }); }
    var order = [];
    async function ticks() { order.push('start'); await 0; order.push('first'); await 'x'; order.push('second'); }
    var done = ticks();
    Promise.resolve().then(function () { order.push('job'); });
    order.push('sync');
    await done;
    check(order.join(','), 'start,sync,first,job,second');
    async function temporary(i) { return await ('owned'.repeat(300) + i); }
    for (var j = 0; j < 150; j++) check(await temporary(j), 'owned'.repeat(300) + j);
    var resolve;
    var pending = new Promise(function (r) { resolve = r; });
    async function mixed() { await 1; var x = await pending; await null; return x; }
    var mixedDone = mixed();
    resolve('pending');
    check(await mixedDone, 'pending');
    async function* generator() { yield await 7; }
    check((await generator().next()).value, 7);
    print('PASS primitive await');
}
verify().catch(function (e) { throw e; });
