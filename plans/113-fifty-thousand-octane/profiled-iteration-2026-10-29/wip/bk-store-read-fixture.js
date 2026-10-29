function step(v) { this.value = v; return this.value; }
var o = { value: 1, step: step };
for (var i = 0; i < 8000; i++) {
    if (o.step(i) !== i || o.value !== i) throw Error('warm');
}
o.extra = 1;
if (o.step(71) !== 71 || o.value !== 71) throw Error('shape');
var got = 0, set = 0, seen = 0;
Object.defineProperty(o, 'value', { configurable: true, get: function () { got++; return seen + 1; }, set: function (v) { set++; seen = v; } });
if (o.step(90) !== 91 || got !== 1 || set !== 1 || seen !== 90) throw Error('accessor effects');
Object.defineProperty(o, 'value', { configurable: true, writable: true, value: 'previous string' });
if (o.step(12) !== 12) throw Error('string replacement');
var p = { value: 0, step: step };
if (p.step(17) !== 17 || p.value !== 17) throw Error('other receiver');
print('store read fusion: PASS');
