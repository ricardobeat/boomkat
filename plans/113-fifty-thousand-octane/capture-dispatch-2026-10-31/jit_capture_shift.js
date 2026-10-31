// A capture read followed by an immediate shift must publish the capture
// before any fallbacks and must preserve coercion and closure mutation.
function create(initial) {
    var value = initial;
    function read() { return value >> 3; }
    function write(v) { value = v; }
    return [read, write];
}
var pair = create(-123456789);
for (var i = 0; i < 5000; i++) {
    if (pair[0]() !== (-123456789 >> 3)) throw Error('negative shift');
}
pair[1](4294967295);
if (pair[0]() !== -1) throw Error('ToInt32 truncation');
pair[1]('24');
if (pair[0]() !== 3) throw Error('string coercion');
var calls = 0;
pair[1]({ valueOf: function () { calls++; return 80; } });
if (pair[0]() !== 10 || calls !== 1) throw Error('object coercion');
pair[1]({ valueOf: function () { calls++; throw new Error('shift failure'); } });
try { pair[0](); throw Error('missing throw'); } catch (e) {
    if (e.message !== 'shift failure' || calls !== 2) throw e;
}
pair[1](32);
if (pair[0]() !== 4) throw Error('mutation after throw');
function tdz() {
    function read() { return value >> 3; }
    try { read(); throw Error('missing TDZ'); } catch (e) {
        if (!(e instanceof ReferenceError)) throw e;
    }
    let value = 16;
    return read();
}
if (tdz() !== 2) throw Error('TDZ recovery');
function arrayReader(array) {
    var captured = array;
    return function (index) { return captured[index >> 3]; };
}
var readArray = arrayReader([7, 11, 13]);
for (var j = 0; j < 5000; j++) if (readArray(8) !== 11) throw Error('captured array index');
var indexCalls = 0;
if (readArray({ valueOf: function () { indexCalls++; return 16; } }) !== 13 || indexCalls !== 1)
    throw Error('index coercion');
print('capture shift ok');
