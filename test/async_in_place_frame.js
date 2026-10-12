var passes = 0;
function check(actual, expected) {
    if (actual !== expected) throw new Error('in-place async: ' + actual + ' !== ' + expected);
    passes++;
}
function deep(n, text) {
    var local = text + n;
    if (n === 0) return local;
    return deep(n - 1, local) + n;
}
async function frame(label) {
    var owned = label.repeat(300);
    var captured = { value: owned };
    var read = function () { return captured.value; };
    await 0;
    for (var i = 0; i < 4; i++) {
        var grown = deep(70, owned);
        check(grown.length > owned.length, true);
        var callback = [1, 2].map(function (n) {
            return deep(35, read()) + n;
        });
        check(callback[0].slice(0, owned.length), owned);
        check(callback[1].slice(0, owned.length), owned);
        await Promise.resolve(0);
        check(read(), owned);
    }
    try { await Promise.reject(owned); }
    catch (e) { check(e, owned); }
    finally { await 1; check(read(), owned); }
    return owned;
}
async function mapped(value) {
    var args = arguments;
    await 0;
    check(args[0], value);
    args[0] = 'after'.repeat(300);
    check(value, args[0]);
    await 0;
    check(value, 'after'.repeat(300));
    return value;
}
async function forIn() {
    var keys = '';
    for (var key in { a: 1, b: 2, c: 3 }) { await 0; keys += key; }
    return keys;
}
function nestedThrow(n) {
    var owned = 'nested'.repeat(300) + n;
    if (n) return nestedThrow(n - 1) + owned;
    throw owned;
}
async function caughtNested() {
    await 0;
    try { nestedThrow(40); }
    catch (e) { check(e, 'nested'.repeat(300) + 0); }
    await 0;
    return 'caught';
}
async function verify() {
    var result = await Promise.all([frame('left'), frame('right'), mapped('before'.repeat(300))]);
    check(result[0], 'left'.repeat(300));
    check(result[1], 'right'.repeat(300));
    check(result[2], 'after'.repeat(300));
    check(await forIn(), 'abc');
    check(await caughtNested(), 'caught');
    for (var i = 0; i < 80; i++) {
        async function thrower() { await 0; deep(30, 'throw'.repeat(100)); throw 'owned'.repeat(300); }
        try { await thrower(); throw new Error('missing rejection'); }
        catch (e) { check(e, 'owned'.repeat(300)); }
    }
    print('PASS in-place async frames: ' + passes);
}
verify().catch(function (e) { print('FAIL ' + e); });
