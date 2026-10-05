function equal(actual, expected) {
    if (actual !== expected) throw new Error(String(actual) + " !== " + String(expected));
}
function patterns([a, {b = 2}], {c = a} = {}, ...[d, e]) {
    equal(a, 1); equal(b, 2); equal(c, 1); equal(d, 3); equal(e, 4);
    var source = {x: [5], y: 6, z: 7};
    let {x: [x], ["y"]: y, ...rest} = source;
    equal(x, 5); equal(y, 6); equal(rest.z, 7);
    var object = {}, calls = 0;
    ({x: [object.value], y: y = ++calls} = source);
    equal(object.value, 5); equal(calls, 0);
    var closures = [];
    for (const [value] of [[8], [9]]) closures.push(() => value);
    equal(closures[0](), 8); equal(closures[1](), 9);
    for (let [i] = [0]; i < 2; i++) closures.push(() => i);
    equal(closures[2](), 0); equal(closures[3](), 1);
    try { throw {message: "caught"}; }
    catch ({message}) { equal(message, "caught"); }
    const constant = 10;
    var threw = false;
    try { [constant] = [11]; } catch (e) { threw = e instanceof TypeError; }
    equal(threw, true); equal(constant, 10);
}
patterns([1, {}], undefined, 3, 4);
function* suspendedDefault() {
    let [x = yield 1] = [];
    yield x;
}
var iterator = suspendedDefault();
equal(iterator.next().value, 1);
equal(iterator.next(12).value, 12);
async function awaitedDefault() {
    let {x = await Promise.resolve(13)} = {};
    equal(x, 13);
}
awaitedDefault().then(function () {}, function (error) { print("FAIL: " + error); });

function parameterTdz(fn) {
    var threw = false;
    try { fn(); } catch (error) { threw = error instanceof ReferenceError; }
    equal(threw, true);
}
parameterTdz(function ([a = b, b] = []) {});
parameterTdz(function ({a = b, b} = {}) {});
parameterTdz(function (a = rest, ...rest) {});
function middle(a = 1, b, c = b) { equal(c, b); }
middle(undefined, 2);
function ordered([a], b = a) { equal(b, a); }
ordered([14]);
equal(ordered.length, 1);
function restTarget() {
    var source = {}, called = 0;
    ({...source.value} = {x: 15});
    equal(source.value.x, 15);
    var destination = {set value(value) { called++; equal(value.x, 16); }};
    ({...destination.value} = {x: 16});
    equal(called, 1);
}
restTarget();
