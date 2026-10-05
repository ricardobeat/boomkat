function equal(actual, expected) {
    if (actual !== expected) throw new Error(String(actual) + " !== " + String(expected));
}
function* generator(value = 1) {
    function ordinary() { return 2; }
    equal(ordinary(), 2);
    var sent = yield value;
    equal(value, 1);
    yield* [sent, 3];
    return 4;
}
var iterator = generator();
equal(iterator.next().value, 1);
equal(iterator.next(2).value, 2);
equal(iterator.next().value, 3);
equal(iterator.next().value, 4);
equal(iterator.next().done, true);
async function awaitLocal() {
    var promise = Promise.resolve(7);
    equal(await promise, 7);
    equal(promise instanceof Promise, true);
    equal(await promise, 7);
    var inner = async x => await x;
    equal(await inner(8), 8);
    var total = 0;
    for await (const value of [1, Promise.resolve(2), 3]) total += value;
    equal(total, 6);
    return 9;
}
async function* asyncGenerator() {
    var promise = Promise.resolve(10);
    yield promise;
    equal(promise instanceof Promise, true);
    yield* [Promise.resolve(11)];
    try { return promise; }
    finally { equal(promise instanceof Promise, true); }
}
async function checkAsync() {
    equal(await awaitLocal(), 9);
    var iterator = asyncGenerator();
    equal((await iterator.next()).value, 10);
    equal((await iterator.next()).value, 11);
    var result = await iterator.next();
    equal(result.value, 10);
    equal(result.done, true);
}
checkAsync().then(function () {}, function (error) { print("FAIL: " + error); });
