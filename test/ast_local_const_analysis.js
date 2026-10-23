function same(actual, expected) {
    if (!Object.is(actual, expected)) throw new Error(String(actual) + ' !== ' + String(expected));
}
function chain() {
    const first = 2;
    const second = first + 3, third = second << 1;
    const text = 'x' + third;
    const nil = void 0;
    return [third + 1, text + '!', nil ?? third, third ? first : 0];
}
same(JSON.stringify(chain()), '[11,"x10!",10,2]');
function shadows() {
    const value = 2;
    var result = value;
    { const value = 5; result += value * 2; }
    { const value = 'x'; result += value + true; }
    if (value === 2) { result += value; }
    return result;
}
same(shadows(), '12xtrue2');
function tdz() {
    var count = 0;
    try { value + 1; } catch (e) { if (e instanceof ReferenceError) count++; }
    try { typeof value; } catch (e) { if (e instanceof ReferenceError) count++; }
    const value = 3;
    return count + value;
}
same(tdz(), 5);
function selfTdz() {
    try { const value = value + 1; } catch (e) { return e instanceof ReferenceError; }
    return false;
}
same(selfTdz(), true);
function shadowTdz() {
    const value = 1;
    try { { value + 1; const value = 2; } } catch (e) { return e instanceof ReferenceError; }
    return false;
}
same(shadowTdz(), true);
function closureBeforeInit() {
    function read() { return value + 1; }
    var count = 0;
    try { read(); } catch (e) { if (e instanceof ReferenceError) count++; }
    const value = 3;
    return read() + count;
}
same(closureBeforeInit(), 5);
function closureAfterInit() { const value = 4; return function () { return value + 1; }; }
same(closureAfterInit()(), 5);
function loop() {
    var result = 0;
    for (var i = 0; i < 3; i++) {
        try { value; } catch (e) { if (e instanceof ReferenceError) result++; }
        const value = 2;
        result += value;
    }
    for (const value of [3, 4]) result += value;
    for (const key in { a: 1, b: 2 }) result += key.length;
    return result;
}
same(loop(), 18);
function switchTdz(mode) {
    switch (mode) {
        case 0: const value = 7;
        case 1: return value;
    }
}
same(switchTdz(0), 7);
var threw = false;
// The engine's existing case-entry path may return undefined instead of a
// TDZ error. In either case, propagation must not invent the initialized 7.
try { same(switchTdz(1) === 7, false); } catch (e) { same(e instanceof ReferenceError, true); }
function evalHazard() {
    const value = 3;
    same(eval('value'), 3);
    try { eval('value = 4'); } catch (e) { same(e instanceof TypeError, true); }
    return value + 1;
}
same(evalHazard(), 4);
same(Function('const value = 3; with ({value: 8}) { return value + 1; }')(), 9);
same(Function('with ({value: 8}) { return (function () { const value = 3; return value + 1; })(); }')(), 4);
function failedInitializer() {
    try { const value = (function () { throw 1; })(); return value + 1; } catch (e) { return e; }
}
same(failedInitializer(), 1);
function writes() {
    const value = 3;
    var throws = 0;
    try { value = 4; } catch (e) { if (e instanceof TypeError) throws++; }
    try { value++; } catch (e) { if (e instanceof TypeError) throws++; }
    try { value &&= 4; } catch (e) { if (e instanceof TypeError) throws++; }
    return throws + value;
}
same(writes(), 6);
function parameterDefault(value = local + 1) { const local = 3; return value; }
threw = false;
try { parameterDefault(); } catch (e) { threw = e instanceof ReferenceError; }
same(threw, true);
function parameterShadow(value) { { const value = 3; same(value + 1, 4); } return value; }
same(parameterShadow(9), 9);
function partialConstants() {
    const base = 3;
    var effects = 0;
    const object = { valueOf: function () { effects++; return 4; } };
    const { value } = { get value() { effects++; return 5; } };
    same(base + object, 7);
    same(value + base, 8);
    return effects;
}
same(partialConstants(), 2);
function localGlobalNames() {
    const undefined = 4, NaN = 5, Infinity = 6;
    return (undefined ?? 1) + (NaN || 2) + (Infinity && 3);
}
same(localGlobalNames(), 12);
function constNames() {
    const flag = true, empty = void 0;
    var fn = flag ? function () {} : 0;
    var cls = flag && class {};
    var arrow = empty ?? (() => 1);
    same(fn.name, ''); same(cls.name, ''); same(arrow.name, '');
    var object = { method: function () { 'use strict'; return this; } };
    same((flag ? (object.method) : 0)(), undefined);
    same((flag && (object.method))(), undefined);
    same((empty ?? (object.method))`tag`, undefined);
}
constNames();
print('local const analysis ok');
