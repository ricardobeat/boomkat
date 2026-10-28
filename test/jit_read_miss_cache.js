function readMissCheck(actual, expected) {
    if (actual !== expected) throw new Error('read miss cache: ' + actual + ' != ' + expected);
}
function readMissValue(object) {
    var a = object.value;
    var b = a + 1;
    var c = b * 2;
    return c + object.value;
}
var readMissOwn = { value: 4 };
for (var key = 0; key < 300; key++) readMissOwn['field' + key] = key;
for (var warm = 0; warm < 200; warm++) readMissCheck(readMissValue(readMissOwn), 14);
var readMissProto = { value: 8 };
delete readMissOwn.value;
Object.setPrototypeOf(readMissOwn, readMissProto);
for (var warm = 0; warm < 200; warm++) readMissCheck(readMissValue(readMissOwn), 26);
Object.setPrototypeOf(readMissOwn, { value: 9 });
readMissCheck(readMissValue(readMissOwn), 29);
readMissOwn.value = 5;
readMissCheck(readMissValue(readMissOwn), 17);
var readMissEffects = 0;
Object.defineProperty(readMissOwn, 'value', {
    configurable: true, get: function () { readMissEffects++; return 6; }
});
readMissCheck(readMissValue(readMissOwn), 20);
readMissCheck(readMissEffects, 2);
delete readMissOwn.value;
readMissCheck(readMissValue(readMissOwn), 29);
var readMissProxy = new Proxy({ value: 7 }, {
    get: function (target, name) { readMissEffects++; return target[name]; }
});
readMissCheck(readMissValue(readMissProxy), 23);
readMissCheck(readMissEffects, 4);
for (var pressure = 0; pressure < 10000; pressure++) {
    var other = { value: pressure }; other['temporary' + pressure] = pressure;
    readMissCheck(readMissValue(other), pressure * 3 + 2);
}
readMissCheck(readMissValue(readMissOwn), 29);
console.log('JIT read miss cache: PASS');
