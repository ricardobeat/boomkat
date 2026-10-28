// Exercise inherited named reads after native compilation, then invalidate the
// receiver link, owner layout and property kind while the function stays hot.
function inheritedRead(o) { return o.value; }
var proto = { value: 11 };
var a = Object.create(proto), b = Object.create(proto);
a.a = 1; b.b = 2; b.c = 3;
for (var i = 0; i < 5000; i++) {
    if (inheritedRead(i % 2 ? a : b) !== 11) throw new Error('warm read');
}
proto.value = 12;
if (inheritedRead(a) !== 12 || inheritedRead(b) !== 12) throw new Error('value write');
a.value = 13;
if (inheritedRead(a) !== 13 || inheritedRead(b) !== 12) throw new Error('shadow');
delete a.value;
Object.setPrototypeOf(a, { value: 14 });
if (inheritedRead(a) !== 14 || inheritedRead(b) !== 12) throw new Error('prototype');
var calls = 0;
Object.defineProperty(proto, 'value', { configurable: true, get: function () { calls++; return 15; } });
if (inheritedRead(b) !== 15 || calls !== 1) throw new Error('accessor');
var prox = new Proxy({}, { get: function (_, k) { return k === 'value' ? 16 : undefined; } });
Object.setPrototypeOf(b, prox);
if (inheritedRead(b) !== 16) throw new Error('proxy');
print('jit_native_inherited_continuation: PASS');
