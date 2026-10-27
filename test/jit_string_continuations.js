function stringCheck(actual, expected) {
    if (actual !== expected) throw new Error('string continuation: ' + actual + ' != ' + expected);
}
function stringLiteral(value) {
    var left = 'prefix:' + value;
    var right = left + ':suffix';
    return { left: left, right: right, nested: { value: value }, array: [1, 2, 3] };
}
function stringScan(text, at) {
    var code = text.charCodeAt(at);
    return code + text.length;
}
function stringNumeric(value, branch) {
    var a = value + 1;
    var b = a * 2;
    if (branch) return 'number:' + b;
    return b + 3;
}
var stringSaved = [];
for (var warm = 0; warm < 200; warm++) {
    var item = stringLiteral(warm);
    stringCheck(item.left, 'prefix:' + warm);
    stringCheck(item.right, 'prefix:' + warm + ':suffix');
    stringCheck(item.nested.value, warm);
    stringCheck(item.array[2], 3);
    if ((warm & 31) === 0) stringSaved.push(item);
    stringCheck(stringScan('abc', 1), 101);
    stringCheck(stringNumeric(3, false), 11);
}
stringCheck(stringScan('\u00e9\ud83d\ude00', 0), 236);
stringCheck(stringScan('\u00e9\ud83d\ude00', 1), 55360);
stringCheck(stringScan('\u00e9\ud83d\ude00', 2), 56835);
stringCheck(stringScan('abc', 1.9), 101);
if (!Number.isNaN(stringScan('abc', -1)) || !Number.isNaN(stringScan('abc', 3)))
    throw new Error('character bounds');
var stringEffects = 0;
var stringInput = { valueOf: function () { stringEffects++; return 4; } };
stringCheck(stringLiteral(stringInput).right, 'prefix:4:suffix');
stringCheck(stringEffects, 1);
stringCheck(stringNumeric('3', false), 65);
stringCheck(stringNumeric(3, true), 'number:8');
var stringOriginal = String.prototype.charCodeAt;
String.prototype.charCodeAt = function () { stringEffects++; return 700; };
stringCheck(stringScan('abc', 1), 703);
stringCheck(stringEffects, 2);
String.prototype.charCodeAt = stringOriginal;
stringCheck(stringScan('abc', 1), 101);
var stringThrows = 0;
try { stringLiteral(Symbol('x')); } catch (e) { if (e instanceof TypeError) stringThrows++; }
try { stringScan(null, 0); } catch (e) { if (e instanceof TypeError) stringThrows++; }
stringCheck(stringThrows, 2);
for (var pressure = 0; pressure < 20000; pressure++) stringLiteral(pressure);
for (var saved = 0; saved < stringSaved.length; saved++) {
    stringCheck(stringSaved[saved].right, 'prefix:' + (saved * 32) + ':suffix');
}
console.log('JIT string continuations: PASS');
