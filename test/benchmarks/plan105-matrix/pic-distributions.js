function make(count, offset, changing) {
    var objects = [];
    for (var i = 0; i < count; i++) {
        var object = {};
        var value = changing && (i & 1) ? 'x' : 1;
        if (offset) for (var j = 0; j < i; j++) object['before' + j] = 0;
        object.value = value;
        object['layout' + i] = 0;
        objects.push(object);
    }
    return objects;
}
function exercise(objects, order, changing) {
    var read = Function('o', 'return o.value;');
    var seed = 12345, sum = 0, mask = objects.length - 1;
    for (var i = 0; i < 100000; i++) {
        var index;
        if (order === 0) index = i & mask;
        else if (order === 1) index = (i >> 6) & mask;
        else { seed = (seed * 1664525 + 1013904223) >>> 0; index = (seed >>> 16) & mask; }
        var value = read(objects[index]);
        sum += changing && typeof value === 'string' ? value.length : value;
    }
    if (sum !== 100000) throw new Error('PIC distribution');
}
var counts = [1,2,4,8,32];
for (var c = 0; c < counts.length; c++) {
    for (var offset = 0; offset < 2; offset++) {
        for (var changing = 0; changing < 2; changing++) {
            var objects = make(counts[c], offset, changing);
            for (var order = 0; order < 3; order++) exercise(objects, order, changing);
        }
    }
}
function dynamic(object, key) { return object[key]; }
var dictionary = {a:1,b:2,c:3,d:4}, keys = ['a','b','c','d'], sum = 0;
for (var i = 0; i < 1000000; i++) sum += dynamic(dictionary, keys[i & 3]);
if (sum !== 2500000) throw new Error('computed key distribution');
print('PASS PIC distributions');
