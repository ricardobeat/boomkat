// Bench 4: Object property access
var obj = { a: 1, b: 2, c: 3, d: 4, e: 5 };
var sum = 0;
for (var i = 0; i < 100000; i++) {
    sum += obj.a + obj.b + obj.c + obj.d + obj.e;
}
