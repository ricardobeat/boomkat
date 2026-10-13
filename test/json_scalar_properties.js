function equal(actual, expected) {
    if (actual !== expected) throw new Error(actual + ' !== ' + expected);
}
function value() {
    return {integer: 7, fraction: 1.25, negativeZero: -0, nan: NaN, infinity: Infinity,
        yes: true, no: false, empty: null, text: 'line\n"\\\0😀\ud800',
        ignored: undefined, symbol: Symbol('ignored')};
}
var expected = '{"integer":7,"fraction":1.25,"negativeZero":0,"nan":null,"infinity":null,"yes":true,"no":false,"empty":null,"text":"line\\n\\"\\\\\\u0000😀\\ud800"}';
for (var i = 0; i < 40; i++) equal(JSON.stringify(value()), expected);
Number.prototype.toJSON = String.prototype.toJSON = function () { throw new Error('primitive hook'); };
equal(JSON.stringify(value()), expected);
delete Number.prototype.toJSON; delete String.prototype.toJSON;
var keys = [];
JSON.stringify(value(), function (key, value) { keys.push(key); return value; });
equal(keys.join(','), ',integer,fraction,negativeZero,nan,infinity,yes,no,empty,text,ignored,symbol');
equal(JSON.stringify({first: 1, last: 2}, ['last']), '{"last":2}');
equal(JSON.stringify({first: 1, last: 2}, null, 2), '{\n  "first": 1,\n  "last": 2\n}');
var object = {first: {toJSON: function () {
    Object.defineProperty(object, 'last', {get: function () { return 42; }, enumerable: true});
    return 11;
}}, last: 2};
equal(JSON.stringify(object), '{"first":11,"last":42}');
var caught = false;
try { JSON.stringify({first: 1, last: 2n}); } catch (error) { caught = error instanceof TypeError; }
equal(caught, true);
BigInt.prototype.toJSON = function (key) { return key + ':' + this.toString(); };
equal(JSON.stringify({first: 1, last: 2n}), '{"first":1,"last":"last:2"}');
delete BigInt.prototype.toJSON;
var deep = {value: 1}, root = deep;
for (var i = 0; i < 150; i++) { deep.child = {value: 1}; deep = deep.child; }
caught = false;
try { JSON.stringify(root); } catch (error) { caught = error instanceof RangeError; }
equal(caught, true);
print('json_scalar_properties: PASS');
