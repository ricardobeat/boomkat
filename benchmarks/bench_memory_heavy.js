// Memory benchmark — comprehensive stress test for peak RSS comparison.
// Tests: object graphs, closures, strings, arrays, prototype chains, GC pressure.

var results = {};

// --- 1. Dense object allocation (50k objects) ---
var objects = [];
for (var i = 0; i < 50000; i++) {
    objects.push({
        id: i,
        name: "obj_" + (i % 1000),
        flag: (i % 2) == 0,
        nested: { x: i * 1.5, y: i / 3, tag: String(i) }
    });
}

// --- 2. String pool (unique strings) ---
var strings = [];
for (var i = 0; i < 10000; i++) {
    strings.push("string_value_" + i + "_" + (i * 7));
}

// --- 3. Large arrays of numbers ---
var bigArray = [];
for (var i = 0; i < 100000; i++) {
    bigArray.push(i * 3.14);
}

// --- 4. Matrix (array of arrays) ---
var matrix = [];
for (var i = 0; i < 500; i++) {
    var row = [];
    for (var j = 0; j < 500; j++) {
        row.push((i + j) % 256);
    }
    matrix.push(row);
}

// --- 5. Closures capturing variables ---
var closures = [];
for (var i = 0; i < 10000; i++) {
    var x = i;
    closures.push(function() { return x + 1; });
}

// --- 6. Prototype chains ---
var baseProto = {
    compute: function() { return this.own * 2; },
    value: 999
};
var chain = [];
for (var i = 0; i < 10000; i++) {
    var child = { __proto__: baseProto, own: i, data: "item_" + i };
    chain.push(child);
}

// --- 7. Map-like object (many keys) ---
var map = {};
for (var i = 0; i < 10000; i++) {
    map["key_" + i] = { val: i, label: "entry" + i };
}

// --- 8. Access patterns (force materialization) ---
var sum = 0;
for (var i = 0; i < objects.length; i++) {
    sum += objects[i].id;
    sum += objects[i].nested.x | 0;
}
for (var i = 0; i < chain.length; i++) {
    sum += chain[i].compute();
}
for (var i = 0; i < closures.length; i++) {
    sum += closures[i]();
}
