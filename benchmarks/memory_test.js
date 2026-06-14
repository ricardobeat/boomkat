// Memory benchmark — exercises object, array, string, and property allocation
// Used to measure peak RSS of each JS engine.
// Adapted for TinyDuck: no __proto__, no prototype chains.

// --- Object allocation ---
var objects = [];
for (var i = 0; i < 5000; i++) {
    objects.push({
        id: i,
        name: "obj_" + (i % 100),
        flag: (i % 2) == 0,
        nested: { x: i * 1.5, y: i / 3, tag: String(i) }
    });
}

// --- String concatenation ---
var str = "";
for (var i = 0; i < 2000; i++) {
    str += String(i) + "-";
}

// --- Array of arrays ---
var matrix = [];
for (var i = 0; i < 200; i++) {
    var row = [];
    for (var j = 0; j < 200; j++) {
        row.push((i + j) % 256);
    }
    matrix.push(row);
}

// --- Deep property access ---
var sum = 0;
for (var i = 0; i < objects.length; i++) {
    sum += objects[i].id;
    sum += objects[i].nested.x | 0;
}

// --- Many small objects ---
var chain = [];
for (var i = 0; i < 2000; i++) {
    var child = { own: i };
    chain.push(child);
}

// Access
var total = 0;
for (var i = 0; i < chain.length; i++) {
    total += chain[i].own;
}
