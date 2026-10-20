function eq(actual, expected) {
    if (actual !== expected) throw new Error('Expected ' + expected + ', got ' + actual);
}
var locales = {};
var options = {};
var calls = 0;
var spy = {
    toLocaleString: function (receivedLocales, receivedOptions) {
        eq(arguments.length, 2);
        eq(receivedLocales, locales);
        eq(receivedOptions, options);
        calls++;
        return 'ok';
    }
};
eq([null, spy, undefined, spy].toLocaleString(locales, options, 'ignored'), ',ok,,ok');
eq(calls, 2);
var numberLocaleString = Number.prototype.toLocaleString;
var bigintLocaleString = BigInt.prototype.toLocaleString;
try {
    Number.prototype.toLocaleString = spy.toLocaleString;
    BigInt.prototype.toLocaleString = spy.toLocaleString;
    eq(new Uint8Array([1, 2]).toLocaleString(locales, options), 'ok,ok');
    eq(new BigInt64Array([1n, 2n]).toLocaleString(locales, options), 'ok,ok');
} finally {
    Number.prototype.toLocaleString = numberLocaleString;
    BigInt.prototype.toLocaleString = bigintLocaleString;
}
var precision = { minimumFractionDigits: 3 };
eq([1234.5].toLocaleString('en', precision), (1234.5).toLocaleString('en', precision));
eq(new Float64Array([1234.5]).toLocaleString('en', precision), (1234.5).toLocaleString('en', precision));
