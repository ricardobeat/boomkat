// Dense indexed reads must reject signed and oversized keys before addressing.
function readIndex(a, i) { return a[i]; }
var a = [10, 20, 30];
for (var i = 0; i < 4000; i++) {
    if (readIndex(a, 1) !== 20) throw Error('dense');
}
a[-1] = 41;
if (readIndex(a, -1) !== 41) throw Error('negative');
if (readIndex(a, -2147483648) !== undefined) throw Error('negative limit');
a[-140737488355328] = 44;
if (readIndex(a, -140737488355328) !== 44) throw Error('fastint minimum');
var large = [];
large[2147483648] = 42;
large[4294967295] = 43;
if (readIndex(large, 2147483648) !== 42) throw Error('large index');
if (readIndex(large, 4294967295) !== 43) throw Error('large property');
if (readIndex(a, 1.5) !== undefined) throw Error('fractional');
var sparse = [1, , 3];
var proto = Object.create(Array.prototype);
proto[1] = 51;
Object.setPrototypeOf(sparse, proto);
if (readIndex(sparse, 1) !== 51) throw Error('prototype hole');
if (readIndex([undefined], 0) !== undefined) throw Error('undefined');
if (readIndex({1: 61}, 1) !== 61) throw Error('ordinary object');
// Values that require retention still survive destination replacement.
var words = ['dynamic-' + Math.random(), {value: 73}];
for (var j = 0; j < 4000; j++) {
    if (readIndex(words, 0) !== words[0]) throw Error('string value');
    if (readIndex(words, 1).value !== 73) throw Error('object value');
}
// Exercise external element storage after growth and named-property creation.
var expanded = [];
for (var n = 0; n < 128; n++) expanded.push(n * 3);
expanded.label = 'expanded';
for (var n = 0; n < 4000; n++) {
    if (readIndex(expanded, n & 127) !== (n & 127) * 3) throw Error('external storage');
}
print('array indexed read ok');
