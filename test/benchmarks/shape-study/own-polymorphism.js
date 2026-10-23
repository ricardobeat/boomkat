// Alternate layouts at one constant-key read, including differing slot indices.
function read(o) { return o.value; }
function run(objects) {
    var sum = 0;
    for (var i = 0; i < 2000000; i++) sum += read(objects[i % objects.length]);
    if (sum !== 2000000) throw new Error('cached value');
}
var objects = [
 {value:1}, {a:0,value:1}, {a:0,b:0,value:1}, {value:1,b:0},
 {c:0,value:1}, {c:0,d:0,value:1}, {e:0,value:1}, {e:0,f:0,value:1}
];
run(objects.slice(0,1));
run(objects.slice(0,2));
run(objects.slice(0,4));
run(objects);
print('PASS');
