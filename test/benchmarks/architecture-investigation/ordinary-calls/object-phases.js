// Split bench_object.js into property-operation phases.
var N = 340000;
var obj = {};
var i;
var start = Date.now();
for (i = 0; i < N; i++) obj.x = i;
print('PHASE set ' + (Date.now() - start));

var sum = 0;
obj.x = 42;
start = Date.now();
for (i = 0; i < N; i++) sum += obj.x;
print('PHASE get ' + (Date.now() - start));

start = Date.now();
for (i = 0; i < N; i++) {
    obj.x = i;
    delete obj.x;
}
print('PHASE delete ' + (Date.now() - start));

var obj2 = { a: 1, b: 2, c: 3, d: 4, e: 5 };
start = Date.now();
for (i = 0; i < N / 5; i++) {
    obj2.a = i;
    obj2.b = i + 1;
    obj2.c = i + 2;
    obj2.d = i + 3;
    obj2.e = i + 4;
}
print('PHASE multi-set ' + (Date.now() - start));

var nested = { level1: { level2: { level3: { value: 42 } } } };
start = Date.now();
for (i = 0; i < N; i++) sum += nested.level1.level2.level3.value;
print('PHASE nested-get ' + (Date.now() - start));
if (sum !== 84 * N || obj2.e !== N / 5 + 3) throw new Error('object phase checksum');
