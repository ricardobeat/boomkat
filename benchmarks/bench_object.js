// Object property operations benchmark
var N = 2000000;
var obj = {};
var i;

// Property set
for (i = 0; i < N; i++) {
    obj.x = i;
}

// Property get
var sum = 0;
obj.x = 42;
for (i = 0; i < N; i++) {
    sum += obj.x;
}

// Property delete
for (i = 0; i < N; i++) {
    obj.x = i;
    delete obj.x;
}

// Multiple properties
var obj2 = { a: 1, b: 2, c: 3, d: 4, e: 5 };
for (i = 0; i < N/5; i++) {
    obj2.a = i;
    obj2.b = i + 1;
    obj2.c = i + 2;
    obj2.d = i + 3;
    obj2.e = i + 4;
}

// Nested object access
var nested = { level1: { level2: { level3: { value: 42 } } } };
for (i = 0; i < N; i++) {
    sum += nested.level1.level2.level3.value;
}

print(sum);
