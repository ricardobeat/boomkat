// Named inherited data reads from arrays must retain their lookup semantics
// when the receiver, its prototype, or the property's descriptor changes.
function arrayNamedRead(a) { return a.marker; }
Array.prototype.marker = 21;
var a = [1, 2], b = [3];
for (var i = 0; i < 5000; i++) {
    if (arrayNamedRead(i & 1 ? a : b) !== 21) throw Error('warm inherited read');
}
Array.prototype.marker = 22;
if (arrayNamedRead(a) !== 22) throw Error('value write');
a.marker = 23;
if (arrayNamedRead(a) !== 23 || arrayNamedRead(b) !== 22) throw Error('own shadow');
delete a.marker;
var calls = 0;
Object.defineProperty(Array.prototype, 'marker', { configurable: true, get: function () { calls++; return 24; } });
if (arrayNamedRead(a) !== 24 || calls !== 1) throw Error('accessor');
Object.defineProperty(Array.prototype, 'marker', { configurable: true, writable: true, value: 25 });
Object.setPrototypeOf(a, { marker: 26 });
if (arrayNamedRead(a) !== 26 || arrayNamedRead(b) !== 25) throw Error('prototype replacement');
var p = new Proxy({}, { get: function (_, k) { return k === 'marker' ? 27 : undefined; } });
Object.setPrototypeOf(a, p);
if (arrayNamedRead(a) !== 27) throw Error('proxy');
if (b.length !== 1 || b[0] !== 3) throw Error('array special keys');
delete Array.prototype.marker;
print('jit_array_named_inherited: PASS');
