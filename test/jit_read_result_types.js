function readPair(o) {
    var first = o.x;
    var second = first;
    return [first, second, o.x];
}
var object = {x: 7};
for (var i = 0; i < 300; i++) {
    var warm = readPair(object);
    if (warm[0] !== 7 || warm[1] !== 7 || warm[2] !== 7) throw Error('warm');
}
for (var j = 0; j < 300; j++) {
    var text = 'dynamic-' + j;
    object.x = text;
    var values = readPair(object);
    object.x = j;
    if (values[0] !== text || values[1] !== text || values[2] !== text) throw Error('string ownership');
    if (readPair(object)[1] !== j) throw Error('numeric reentry');
}
var calls = 0;
Object.defineProperty(object, 'x', {get: function () { calls++; return 'getter-' + calls; }});
var result = readPair(object);
if (calls !== 2 || result[0] !== 'getter-1' || result[1] !== 'getter-1' || result[2] !== 'getter-2')
    throw Error('accessor effects');
print('read result types ok');
